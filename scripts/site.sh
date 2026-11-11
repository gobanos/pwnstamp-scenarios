#!/usr/bin/env bash
# The scenario pages, https://scenarios.pwnstamp.org: one page per scenario id, plus the rules and
# an index. Ids are computed here from each scenario directory, as the ceremony computes them.
#
#   scripts/site.sh ids          print `<dir> <id> <draft|ready>` for every scenario directory
#   scripts/site.sh build SITE   archive the ready scenarios into SITE, then render SITE
#
# SITE is append-only: a scenario whose id is already in SITE is left as it is, and nothing is
# ever removed, so an updated scenario keeps the page of its previous id (marked superseded).
# A draft scenario gets no page, so an id that is never issued is never published: mark a
# scenario draft until its ceremony. While a scenario is draft, its pages already published stay
# current.
# CI keeps SITE on the gh-pages branch (.github/workflows/pages.yml).
#
# Each scenario's compose.yaml carries what the files can't say:
#
#   x-pwnstamp:
#     name: node:26.13.0-trixie-slim   # SPEC §4.3 name: the target's official image reference
#     vm: "2026.11.10"                 # the pwnstamp-vm release the scenario runs on
#     draft: true                      # optional: no page yet (not in the run definition)
#
# Needs docker (compose config only, no daemon access), jq, curl, openssl, and pwnstamp-source and
# pwnstamp-compose from https://github.com/gobanos/pwnstamp (on PATH, or PWNSTAMP_BIN=<dir>).

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VM_RELEASES=https://github.com/gobanos/pwnstamp-vm/releases/download
REPO_URL=https://github.com/gobanos/pwnstamp-scenarios
SITE_URL=https://scenarios.pwnstamp.org
COMMIT=${GITHUB_SHA:-$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo unknown)}

log() { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

tool() {
    local bin=${PWNSTAMP_BIN:+$PWNSTAMP_BIN/}$1
    command -v "$bin" >/dev/null || die "missing $1: cargo install --git https://github.com/gobanos/pwnstamp $1"
    shift
    "$bin" "$@"
}

sha256_hex() { openssl dgst -sha256 -r | cut -d' ' -f1; }
esc() { jq -Rr @html <<<"$1"; }

scenario_dirs() {
    local f
    for f in "$REPO_DIR"/*/compose.yaml; do
        [[ -f $f ]] && basename "$(dirname "$f")"
    done
}

# --- Derivation (SPEC §4.3) ----------------------------------------------------------------------

# Sets CONFIG, NAME, VM_RELEASE, DRAFT, TARGET, IMAGE, USER_UID, SOURCES, RUN_JSON, VM_JSON,
# TUPLE_JSON and ID for the scenario directory $1.
derive() {
    local dir=$REPO_DIR/$1
    [[ $1 =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die "$1: directory names are [a-z0-9-], 1 to 63"
    CONFIG=$(docker compose --project-directory "$dir" -p "scenario-$1" -f "$dir/compose.yaml" \
        config --format json) || die "$1: invalid compose.yaml"

    NAME=$(jq -r '."x-pwnstamp".name // ""' <<<"$CONFIG")
    VM_RELEASE=$(jq -r '."x-pwnstamp".vm // ""' <<<"$CONFIG")
    [[ $NAME =~ ^[A-Za-z0-9][A-Za-z0-9._/:-]{0,254}$ ]] || die "$1: x-pwnstamp.name missing or invalid"
    [[ $VM_RELEASE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "$1: x-pwnstamp.vm missing or invalid"
    DRAFT=$(jq -r '."x-pwnstamp" | if has("draft") then .draft else false end' <<<"$CONFIG")
    [[ $DRAFT == true || $DRAFT == false ]] || die "$1: x-pwnstamp.draft must be true or false"

    # The target: the one container with `expose` (SPEC §4.3.1).
    TARGET=$(jq -r '[.services | to_entries[] | select(.value.expose) | .key]
        | if length == 1 then .[0] else "" end' <<<"$CONFIG")
    [[ -n $TARGET ]] || die "$1: exactly one service must have expose"
    IMAGE=$(jq -r --arg t "$TARGET" '.services[$t].image' <<<"$CONFIG")
    [[ $IMAGE =~ ^([a-z0-9._/:-]+)@sha256:[0-9a-f]{64}$ ]] || die "$1: $TARGET image must be pinned by digest"
    # The name is the target's image reference: same repository, plus a tag.
    local repo=${BASH_REMATCH[1]} tagless=${NAME%:*}
    [[ $NAME == *:* && ${NAME##*:} != */* && $tagless == "$repo" ]] \
        || die "$1: x-pwnstamp.name $NAME is not <$repo>:<tag>"
    USER_UID=$(jq -r --arg t "$TARGET" '.services[$t].user // ""' <<<"$CONFIG")
    USER_UID=${USER_UID%%:*}
    [[ $USER_UID =~ ^[1-9][0-9]*$ ]] || die "$1: $TARGET user must be a non-zero numeric uid"

    # Volume sources by digest: a dir by its source manifest, a file by its contents.
    SOURCES='{}'
    local src type digest
    while IFS= read -r src; do
        [[ -e $src ]] || die "$1: volume source $src not found"
        if [[ -d $src ]]; then
            type=dir digest=$(tool pwnstamp-source digest "$src")
        else
            type=file digest=sha256:$(sha256_hex <"$src")
        fi
        SOURCES=$(jq -c --arg s "$src" --arg d "$digest" --arg t "$type" \
            '.[$s] = {source: $d, type: $t}' <<<"$SOURCES")
    done < <(jq -r '.services[].volumes // [] | .[].source' <<<"$CONFIG")

    # The run definition, as scripts/compose-local.sh in pwnstamp builds it. `jq -cS` gives JCS
    # here: sorted keys, no whitespace, ASCII strings.
    RUN_JSON=$(jq -cS --argjson sources "$SOURCES" '{containers: (.services | map_values(
        {image, base, command, user, working_dir, environment, expose,
         volumes: (if .volumes then .volumes
            | map(select(.read_only == true or error("volume \(.target) is not read-only"))
                  | $sources[.source] + {target})
            | sort_by(.target) else null end)}
        | with_entries(select(.value != null))))}' <<<"$CONFIG") || die "$1: bad volumes"
    jq -e '[.containers[] | keys[]] - ["base","command","environment","expose","image","user",
        "volumes","working_dir"] == []' <<<"$RUN_JSON" >/dev/null || die "$1: unexpected run member"

    # The VM definition, exactly as released (JCS, maybe one trailing newline).
    VM_JSON=$(curl -fsSL "$VM_RELEASES/$VM_RELEASE/vm.json") || die "$1: no vm.json in pwnstamp-vm $VM_RELEASE"
    [[ $(jq -cS . <<<"$VM_JSON") == "$VM_JSON" ]] || die "$1: vm.json of $VM_RELEASE is not JCS"

    local run_digest vm_digest
    run_digest=sha256:$(printf '%s' "$RUN_JSON" | sha256_hex)
    vm_digest=sha256:$(printf '%s' "$VM_JSON" | sha256_hex)
    TUPLE_JSON=$(printf '{"level.user.uid":"%s","run":"%s","vm":"%s"}' "$USER_UID" "$run_digest" "$vm_digest")
    ID=$NAME@$(printf '%s' "$TUPLE_JSON" | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | cut -c1-8)
}

# The publication of the derived scenario into $1: compose.yaml from pwnstamp-compose, and
# scenario.tar.gz (compose.yaml and sources/, as players run it), checked against compose.yaml.
publish() {
    local out=$1 work src digest strip
    work=$(mktemp -d)
    mkdir -p "$work/pub/sources"
    printf '%s' "$RUN_JSON" | tool pwnstamp-compose - >"$work/pub/compose.yaml"
    while IFS=$'\t' read -r src digest; do
        local dst=$work/pub/sources/${digest#sha256:}
        cp -r "$src" "$dst"
        if [[ -d $dst ]]; then
            # Modes as a source is materialized (crates/pwnstamp-source/SPEC.md in pwnstamp).
            find "$dst" -type d -exec chmod 0755 {} +
            find "$dst" -type f -perm /111 -exec chmod 0755 {} +
            find "$dst" -type f ! -perm /111 -exec chmod 0644 {} +
            tool pwnstamp-source manifest "$dst" | tr -d '\n' >"$dst.json"
            tool pwnstamp-source check "$dst" "$digest" || die "published $dst does not match $digest"
        fi
    done < <(jq -r 'to_entries[] | [.key, .value.source] | @tsv' <<<"$SOURCES")
    # Same containers as the scenario's own compose.yaml, apart from sources and local ports.
    strip='.services | map_values(del(.volumes[]?.source, .volumes[]?.bind, .ports, .networks)
        | with_entries(select(.value != null)))'
    diff <(jq -S "$strip" <<<"$CONFIG") \
        <(docker compose --project-directory "$work/pub" -p pub -f "$work/pub/compose.yaml" \
            config --format json | jq -S "$strip") >&2 \
        || die "published compose.yaml differs from the scenario's"
    chmod 0755 "$work/pub/sources"
    chmod 0644 "$work/pub/compose.yaml"
    cp "$work/pub/compose.yaml" "$out/compose.yaml"
    # Reproducible: same sources, same bytes.
    tar -C "$work/pub" --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 -cf - \
        compose.yaml sources | gzip -n >"$out/scenario.tar.gz"
    rm -rf "$work"
}

# Writes SITE/<id>/ for the scenario directory $2, unless that id is already archived.
archive() {
    local site=$1 dir=$2 out
    derive "$dir"
    out=$site/$ID
    if [[ -f $out/tuple.json ]]; then
        [[ $(cat "$out/tuple.json") == "$TUPLE_JSON" ]] || die "$ID: archived with another tuple"
        log "$dir: $ID already archived"
        return
    fi
    log "$dir: archiving $ID"
    mkdir -p "$out"
    printf '%s' "$TUPLE_JSON" >"$out/tuple.json"
    printf '%s' "$RUN_JSON" >"$out/run.json"
    printf '%s' "$VM_JSON" >"$out/vm.json"
    publish "$out"
    jq -n --arg id "$ID" --arg name "$NAME" --arg dir "$dir" --arg vm "$VM_RELEASE" \
        --arg target "$TARGET" --arg commit "$COMMIT" --arg date "$(date -u +%Y-%m-%d)" \
        '{id: $id, name: $name, dir: $dir, vm_release: $vm, target: $target, commit: $commit,
          published: $date}' >"$out/meta.json"
}

# --- Rendering -----------------------------------------------------------------------------------

# Page head and header: $1 title, $2 the header's meta lines (HTML).
head_html() {
    cat <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>$1</title>
<link rel="stylesheet" href="/style.css">
</head>
<body>
<main>
  <header>
    <a class="word d" href="/">pwnstamp<i></i></a>
    <div class="meta">$2</div>
  </header>
EOF
}

foot_html() {
    cat <<EOF
  <section>
    <h2 class="d">Reference</h2>
    <div>
      <a class="lnk" href="/"><b class="d">Scenarios</b><span>Every scenario, current and superseded</span><i>→</i></a>
      <a class="lnk" href="/rules"><b class="d">Rules</b><span>Scope, no egress, shared machine, abuse contact</span><i>→</i></a>
      <a class="lnk" href="https://verify.pwnstamp.org/"><b class="d">Verify a proof</b><span>verify.pwnstamp.org</span><i>→</i></a>
    </div>
  </section>
</main>
</body>
</html>
EOF
}

# A table row: label, then HTML.
row() { printf '        <tr><td>%s</td><td>%s</td></tr>\n' "$1" "$2"; }

# The page of the archived scenario in directory $1; $2 is "current" or "superseded".
render_scenario() {
    local d=$1 status=$2 id name dir vm_rel target published commit url tuple_digest
    id=$(jq -r .id "$d/meta.json"); name=$(jq -r .name "$d/meta.json"); dir=$(jq -r .dir "$d/meta.json")
    vm_rel=$(jq -r .vm_release "$d/meta.json"); target=$(jq -r .target "$d/meta.json")
    published=$(jq -r .published "$d/meta.json"); commit=$(jq -r .commit "$d/meta.json")
    url="$SITE_URL/$id/"
    tuple_digest=sha256:$(sha256_hex <"$d/tuple.json")
    local uid run_d vm_d
    uid=$(jq -r '."level.user.uid"' "$d/tuple.json"); run_d=$(jq -r .run "$d/tuple.json"); vm_d=$(jq -r .vm "$d/tuple.json")
    local hot="" status_text=Current
    [[ $status == superseded ]] && hot=' class="hot"' status_text=Superseded

    {
        head_html "$(esc "$id") · pwnstamp" "SCENARIO<br>$(esc "$id")<br>PUBLISHED $(esc "$published")"
        cat <<EOF
  <section>
    <h2 class="d">Scenario</h2>
    <div>
      <div class="name d">$(esc "$name")</div>
      <div class="id"><span class="label">Scenario id</span><code>$(esc "$id")</code></div>
      <div class="stats">
        <div><span>Levels in scope</span><b class="d">user · root</b></div>
        <div><span>User uid</span><b class="d">$(esc "$uid")</b></div>
        <div$hot><span>Status</span><b class="d">$status_text</b></div>
      </div>
EOF
        [[ $status == superseded ]] && cat <<EOF
      <p class="note">The scenario in <code>$(esc "$dir")/</code> has changed since: this id is no
        longer issued, but its proofs stay valid and this page stays.</p>
EOF
        cat <<EOF
    </div>
  </section>

  <section>
    <h2 class="d">Reproduce</h2>
    <div>
      <p>The target as the platform runs it: the same images by digest, the same sources.</p>
      <pre><code>curl -fsSLO '$(esc "${url}scenario.tar.gz")'
tar xzf scenario.tar.gz
docker compose up</code></pre>
      <p class="note">Each <code>sources/&lt;hex&gt;/</code> can be checked against its digest with
        <code>pwnstamp-source check sources/&lt;hex&gt; sha256:&lt;hex&gt;</code>. The platform
        mounts its machine files read-only at <code>/run/pwnstamp</code> in the target.</p>
    </div>
  </section>

  <section>
    <h2 class="d">Containers</h2>
    <div>
EOF
        jq -r --arg target "$target" '.containers | to_entries[] |
            "      <table class=\"kv\">",
            "        <tr><td>Container</td><td><b>\(.key | @html)</b>\(if .key == $target then " <span class=\"pill\">TARGET</span>" else "" end)</td></tr>",
            "        <tr><td>Image</td><td><code>\(.value.image | @html)</code></td></tr>",
            (if .value.base then "        <tr><td>Base</td><td><code>\(.value.base | @html)</code></td></tr>" else empty end),
            (if .value.command then "        <tr><td>Command</td><td><code>\(.value.command | tojson | @html)</code></td></tr>" else empty end),
            (if .value.user then "        <tr><td>User</td><td><code>\(.value.user | @html)</code></td></tr>" else empty end),
            (if .value.working_dir then "        <tr><td>Working dir</td><td><code>\(.value.working_dir | @html)</code></td></tr>" else empty end),
            (if .value.environment then "        <tr><td>Environment</td><td>\([.value.environment | to_entries[] | "<code>\("\(.key)=\(.value)" | @html)</code>" ] | join("<br>"))</td></tr>" else empty end),
            (if .value.expose then "        <tr><td>Port</td><td><code>\(.value.expose | join(", ") | @html)</code></td></tr>" else empty end),
            (.value.volumes // [] | .[] | "        <tr><td>Volume</td><td><code>\(.target | @html)</code> (\(.type), read-only)<small><code>\(.source | @html)</code></small></td></tr>"),
            "      </table>"' "$d/run.json"
        cat <<EOF
    </div>
  </section>

  <section>
    <h2 class="d">Tuple</h2>
    <div>
      <p>The identity of the scenario (SPEC §4.3): any change to it makes another scenario. The id
        suffix is the start of the base64url SHA-256 of <a href="tuple.json">tuple.json</a>,
        <code>$(esc "$tuple_digest")</code>.</p>
      <table class="kv">
$(row Run "<a href=\"run.json\"><code>$(esc "$run_d")</code></a><small>Run definition: containers, images, sources.</small>")
$(row "User uid" "<code>$(esc "$uid")</code><small>The account of the <code>user</code> level in the target.</small>")
$(row VM "<a href=\"vm.json\"><code>$(esc "$vm_d")</code></a><small>Guest kernel, command line and root filesystem.</small>")
      </table>
    </div>
  </section>

  <section>
    <h2 class="d">Guest VM</h2>
    <div>
      <table class="kv">
$(row Release "<a href=\"https://github.com/gobanos/pwnstamp-vm/releases/tag/$(esc "$vm_rel")\">pwnstamp-vm $(esc "$vm_rel")</a>")
$(row Kernel "<a href=\"$(jq -r '.kernel.url | @html' "$d/vm.json")\">$(jq -r '.kernel.url | split("/") | last | @html' "$d/vm.json")</a><small><code>$(jq -r '.kernel.digest | @html' "$d/vm.json")</code></small>")
$(row "Root fs" "<a href=\"$(jq -r '.rootfs.url | @html' "$d/vm.json")\">$(jq -r '.rootfs.url | split("/") | last | @html' "$d/vm.json")</a><small><code>$(jq -r '.rootfs.digest | @html' "$d/vm.json")</code></small>")
$(row "Command line" "<code>$(jq -r '.cmdline | @html' "$d/vm.json")</code>")
      </table>
    </div>
  </section>

  <section>
    <h2 class="d">Files</h2>
    <div>
      <a class="lnk" href="scenario.tar.gz"><b class="d">scenario.tar.gz</b><span>compose.yaml and sources/</span><i>↓</i></a>
      <a class="lnk" href="compose.yaml"><b class="d">compose.yaml</b><span>Generated from the run definition</span><i>↓</i></a>
      <a class="lnk" href="tuple.json"><b class="d">tuple.json</b><span>Exact bytes (JCS)</span><i>↓</i></a>
      <a class="lnk" href="run.json"><b class="d">run.json</b><span>Exact bytes (JCS)</span><i>↓</i></a>
      <a class="lnk" href="vm.json"><b class="d">vm.json</b><span>Exact bytes (JCS)</span><i>↓</i></a>
      <a class="lnk" href="$(esc "$REPO_URL/tree/$commit/$dir")"><b class="d">Source</b><span>$(esc "$dir/") at ${commit:0:12}</span><i>→</i></a>
    </div>
  </section>

EOF
        foot_html
    } >"$d/index.html"
}

render_index() {
    local site=$1 current=$2 meta
    {
        head_html "pwnstamp scenarios" "SCENARIOS<br>$(esc "$SITE_URL" | sed 's|https://||')"
        cat <<EOF
  <section>
    <h2 class="d">Scenarios</h2>
    <div>
      <p>Every scenario ever published. Superseded ones are no longer issued; their proofs stay
        valid. Players attack only the targets, under the <a href="/rules">rules</a>.</p>
EOF
        find "$site" -name meta.json -not -path '*/.git/*' -exec cat {} + \
            | jq -rs --argjson current "$current" '
                if length == 0 then "      <p class=\"note\">No scenario yet.</p>" else
                sort_by(.name, .published) | reverse | .[] |
                "      <a class=\"scn\" href=\"/\(.id | @html)/\"><b class=\"d\">\(.name | @html)</b>" +
                "<code>\(.id | split("@") | last | @html)</code>" +
                (if (.id | IN($current[])) then "<span class=\"pill s\">CURRENT</span>"
                 else "<span class=\"pill\">SUPERSEDED</span>" end) +
                "<small>\(.published | @html)</small></a>" end'
        cat <<EOF
    </div>
  </section>

EOF
        foot_html
    } >"$site/index.html"
}

render_rules() {
    local site=$1
    grep -q 'TODO' "$REPO_DIR/site/rules.html" && die "site/rules.html still has a TODO"
    mkdir -p "$site/rules"
    { head_html "Rules · pwnstamp" "RULES"; cat "$REPO_DIR/site/rules.html"; echo; foot_html; } >"$site/rules/index.html"
}

cmd_ids() {
    local dir
    for dir in $(scenario_dirs); do
        derive "$dir"
        printf '%s %s %s\n' "$dir" "$ID" "$([[ $DRAFT == true ]] && echo draft || echo ready)"
    done
}

cmd_build() {
    local site=$1 dir current='[]' drafts='[]' meta id
    mkdir -p "$site"
    for dir in $(scenario_dirs); do
        derive "$dir"
        if [[ $DRAFT == true ]]; then
            log "$dir: draft ($ID), no page"
            drafts=$(jq -c --arg d "$dir" '. + [$d]' <<<"$drafts")
            continue
        fi
        archive "$site" "$dir"
        current=$(jq -c --arg id "$ID" '. + [$id]' <<<"$current")
    done
    # A draft doesn't supersede anything yet: the pages of its directory stay current.
    if [[ $drafts != '[]' ]]; then
        current=$(find "$site" -name meta.json -not -path '*/.git/*' -exec cat {} + \
            | jq -cs --argjson cur "$current" --argjson drafts "$drafts" \
                '$cur + [.[] | select(.dir | IN($drafts[])) | .id]')
    fi
    log "Rendering $site"
    while IFS= read -r meta; do
        id=$(jq -r .id "$meta")
        if jq -e --arg id "$id" 'index($id)' <<<"$current" >/dev/null; then
            render_scenario "$(dirname "$meta")" current
        else
            render_scenario "$(dirname "$meta")" superseded
        fi
    done < <(find "$site" -name meta.json -not -path '*/.git/*')
    render_index "$site" "$current"
    render_rules "$site"
    cp "$REPO_DIR/site/style.css" "$site/style.css"
    rm -rf "$site/fonts" && cp -r "$REPO_DIR/site/fonts" "$site/fonts"
    touch "$site/.nojekyll"
}

case ${1:-} in
    ids) (($# == 1)) || die "usage: scripts/site.sh ids"; cmd_ids ;;
    build) (($# == 2)) || die "usage: scripts/site.sh build SITE"; cmd_build "$2" ;;
    *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac

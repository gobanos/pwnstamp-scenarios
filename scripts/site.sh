#!/usr/bin/env bash
# The scenario pages, https://scenarios.pwnstamp.org: one page per scenario id, plus the rules and
# an index. Ids are computed here from each scenario directory, as the ceremony computes them.
#
#   scripts/site.sh ids          print `<dir> <id> <draft|ready>` for every scenario directory
#   scripts/site.sh import PEM…  file the intermediates of a ceremony (USB_DIR/intermediates/*.pem)
#                                into intermediates/<dir>/<id suffix>-<epoch>.pem, checked
#   scripts/site.sh build SITE   archive the ready scenarios and their intermediates into SITE,
#                                then render SITE
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
# Intermediates are checked against root-beta.pem (its fingerprint is pinned below): signed by
# the root, CA with pathlen 0, CN `<id>/<epoch>`, and a scenario extension naming that id's
# tuple. After a ceremony: `import`, remove the scenario's `draft`, commit both together.
#
# Needs docker (compose config only, no daemon access), jq, curl, openssl, and pwnstamp-source and
# pwnstamp-compose from https://github.com/gobanos/pwnstamp (on PATH, or PWNSTAMP_BIN=<dir>).

set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VM_RELEASES=https://github.com/gobanos/pwnstamp-vm/releases/download
REPO_URL=https://github.com/gobanos/pwnstamp-scenarios
SITE_URL=https://scenarios.pwnstamp.org
ROOT_PEM=${ROOT_PEM:-$REPO_DIR/root-beta.pem}
# SHA-256 of the beta root DER, as in https://github.com/gobanos/pwnstamp and _root.pwnstamp.org.
ROOT_FP=${ROOT_FP:-7f42e3d2306087abc35ffcaa7cc5e63c7e6dd0c378bbfd41070f38d015234b39}
SCENARIO_EXT=1.3.6.1.4.1.67557.1.1   # id-pwnstamp-ext-scenario, SPEC §3
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
unhex() { tr a-f A-F <<<"$1" | basenc --base16 -d; }

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

# --- Intermediates (SPEC §4.2, §4.3) -------------------------------------------------------------

check_root() {
    [[ $(openssl x509 -in "$ROOT_PEM" -outform DER | sha256_hex) == "$ROOT_FP" ]] \
        || die "$ROOT_PEM is not the root $ROOT_FP"
}

# Checks the intermediate $1 and sets CERT_ID, CERT_EPOCH and CERT_TUPLE (its tuple digest).
check_intermediate() {
    local f=$1 cn hex ref name tuple suffix
    openssl verify -no_check_time -CAfile "$ROOT_PEM" "$f" >/dev/null 2>&1 \
        || die "$f: not signed by the root"
    openssl x509 -in "$f" -noout -ext basicConstraints 2>/dev/null | grep -q 'CA:TRUE, pathlen:0' \
        || die "$f: not an intermediate (CA, pathlen 0)"
    cn=$(openssl x509 -in "$f" -noout -subject -nameopt RFC2253 | sed -n 's/^subject=CN=//p')
    [[ $cn =~ ^([A-Za-z0-9][A-Za-z0-9._/:-]{0,254}@[A-Za-z0-9_-]{8})/([0-9]{6})$ ]] \
        || die "$f: subject is not CN=<scenario id>/<epoch>"
    CERT_ID=${BASH_REMATCH[1]} CERT_EPOCH=${BASH_REMATCH[2]}
    # extnValue: a DER UTF8String holding the scenario reference (JSON, JCS).
    hex=$(openssl x509 -in "$f" -outform DER | openssl asn1parse -inform DER \
        | grep -A1 ":$SCENARIO_EXT\$" | sed -n 's/.*\[HEX DUMP\]://p')
    [[ -n $hex ]] || die "$f: no scenario extension"
    ref=$(unhex "$hex" | openssl asn1parse -inform DER | sed -n 's/^ *0:.*UTF8STRING *://p')
    [[ $(jq -cS . <<<"$ref" 2>/dev/null) == "$ref" ]] || die "$f: scenario extension is not JCS JSON"
    name=$(jq -r .name <<<"$ref") tuple=$(jq -r .tuple <<<"$ref")
    [[ $tuple =~ ^sha256:[0-9a-f]{64}$ ]] || die "$f: bad tuple digest"
    suffix=$(unhex "${tuple#sha256:}" | base64 | tr '+/' '-_' | cut -c1-8)
    [[ $CERT_ID == "$name@$suffix" ]] || die "$f: CN $CERT_ID does not match its extension ($name, $tuple)"
    CERT_TUPLE=$tuple
}

# Files ceremony output into intermediates/<dir>/<suffix>-<epoch>.pem, by the current ids.
cmd_import() {
    local ids='{}' dir f dest
    check_root
    for dir in $(scenario_dirs); do
        derive "$dir"
        ids=$(jq -c --arg id "$ID" --arg d "$dir" --arg t "sha256:$(printf '%s' "$TUPLE_JSON" | sha256_hex)" \
            '.[$id] = {dir: $d, tuple: $t}' <<<"$ids")
    done
    for f in "$@"; do
        check_intermediate "$f"
        dir=$(jq -r --arg id "$CERT_ID" '.[$id].dir // ""' <<<"$ids")
        [[ -n $dir ]] || die "$f: $CERT_ID is not the id of any scenario here"
        [[ $(jq -r --arg id "$CERT_ID" '.[$id].tuple' <<<"$ids") == "$CERT_TUPLE" ]] \
            || die "$f: tuple differs from $dir's"
        dest=$REPO_DIR/intermediates/$dir/${CERT_ID##*@}-$CERT_EPOCH.pem
        mkdir -p "$(dirname "$dest")"
        if [[ -f $dest ]]; then
            cmp -s <(openssl x509 -in "$f") "$dest" || die "$dest exists with another certificate"
            log "$CERT_ID/$CERT_EPOCH: already filed"
            continue
        fi
        openssl x509 -in "$f" >"$dest"
        log "$CERT_ID/$CERT_EPOCH: intermediates/$dir/${dest##*/}"
    done
}

# Copies every filed intermediate to SITE/<id>/intermediates/<epoch>.pem (append-only).
archive_intermediates() {
    local site=$1 f out
    for f in "$REPO_DIR"/intermediates/*/*.pem; do
        [[ -f $f ]] || continue
        check_intermediate "$f"
        [[ ${f##*/} == "${CERT_ID##*@}-$CERT_EPOCH.pem" ]] || die "$f: name differs from its CN"
        [[ -f $site/$CERT_ID/tuple.json ]] \
            || die "$f: $CERT_ID has no page (is its scenario still draft?)"
        [[ sha256:$(sha256_hex <"$site/$CERT_ID/tuple.json") == "$CERT_TUPLE" ]] \
            || die "$f: tuple differs from the archived one"
        out=$site/$CERT_ID/intermediates/$CERT_EPOCH.pem
        if [[ -f $out ]]; then
            cmp -s "$f" "$out" || die "$out: archived with another certificate"
            continue
        fi
        mkdir -p "${out%/*}"
        cp "$f" "$out"
        log "$CERT_ID: intermediate $CERT_EPOCH archived"
    done
}

# The intermediates section of a scenario page, from $1/intermediates/.
intermediates_html() {
    local d=$1 f nb na any=
    for f in "$d"/intermediates/*.pem; do
        [[ -f $f ]] || continue
        if [[ -z $any ]]; then any=1; echo '      <table class="kv">'; fi
        nb=$(openssl x509 -in "$f" -noout -startdate -dateopt iso_8601 | sed 's/^notBefore=//; s/ .*//')
        na=$(openssl x509 -in "$f" -noout -enddate -dateopt iso_8601 | sed 's/^notAfter=//; s/ .*//')
        row "$(basename "$f" .pem)" "<a href=\"intermediates/$(basename "$f")\">$(basename "$f")</a><small>Valid $nb to $na</small>"
    done
    if [[ -n $any ]]; then echo '      </table>'; else echo '      <p class="note">None published yet.</p>'; fi
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
    <h2 class="d">Intermediates</h2>
    <div>
      <p>One per monthly epoch, signed by the <a href="/root-beta.pem">beta root</a>. The leaves
        of each instance are signed by the intermediate of their epoch.</p>
$(intermediates_html "$d")
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

  <section>
    <h2 class="d">Root</h2>
    <div>
      <p>Every scenario's intermediates are signed by the beta root,
        <a href="/root-beta.pem">root-beta.pem</a>. SHA-256 of the certificate:</p>
      <pre><code>$ROOT_FP</code></pre>
      <p class="note">Also in DNS: <code>dig +short TXT _root.pwnstamp.org</code>.</p>
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
    check_root
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
    archive_intermediates "$site"
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
    cp "$ROOT_PEM" "$site/root-beta.pem"
    rm -rf "$site/fonts" && cp -r "$REPO_DIR/site/fonts" "$site/fonts"
    touch "$site/.nojekyll"
}

case ${1:-} in
    ids) (($# == 1)) || die "usage: scripts/site.sh ids"; cmd_ids ;;
    import) (($# >= 2)) || die "usage: scripts/site.sh import PEM..."; shift; cmd_import "$@" ;;
    build) (($# == 2)) || die "usage: scripts/site.sh build SITE"; cmd_build "$2" ;;
    *) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac

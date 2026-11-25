#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status
set -o pipefail  # Return the exit status of the last command in the pipe that failed

# Normalize Go builder image versions in Dockerfiles / Containerfiles /
# Tiltfiles.
#
# Problem: Dockerfiles that pin a Go patch version (e.g. golang:1.25.7)
# miss future CVE fixes because the tag never moves.  Using just the
# minor version (golang:1.25) always resolves to the latest patch.
#
# What this script does:
#   1. Finds all Dockerfile*, Containerfile*, *.Dockerfile (e.g.
#      konflux.Dockerfile) and Tiltfile* in the repository.  Tiltfiles
#      embed a dockerfile (container_build) whose FROM lines reference
#      the same "golang:" images, e.g. velero's tilt-helper image.
#   2. In FROM lines that reference the upstream "golang:" image,
#      strips the patch version: golang:1.25.7-bookworm -> golang:1.25-bookworm
#   3. Leaves non-golang images untouched (konveyor/builder, brew.registry,
#      registry.ci.openshift.org, ubi, distroless, etc.).
#   4. Commits if anything changed.
#
# This is safe because:
#   - "golang:1.25" is a floating tag that always points to the latest
#     1.25.x release, which includes security fixes.
#   - Downstream builds (konflux.Dockerfile, Dockerfile.ubi) already use
#     Red Hat builder images that don't pin patch versions.

stage_and_commit(){
    local message="${1:-UPSTREAM: <drop>: Normalize Go version in Dockerfiles}"

    if [[ -z "$REBASEBOT_GIT_USERNAME" || -z "$REBASEBOT_GIT_EMAIL" ]]; then
        author_flag=()
    else
        author_flag=(--author="$REBASEBOT_GIT_USERNAME <$REBASEBOT_GIT_EMAIL>")
    fi

    if [[ -n $(git status --porcelain) ]]; then
        git add -A
        git commit "${author_flag[@]}" -q -m "$message"
    fi
}

normalize_dockerfiles() {
    echo "Normalizing Go builder versions in Dockerfiles/Tiltfiles"

    local changed=0

    # Find all Dockerfile* and Containerfile* (any depth)
    while IFS= read -r -d '' dockerfile; do
        # Only process files that have a golang: FROM instruction with a
        # patch version.  A FROM instruction starts a line, or follows the
        # opening quote of an embedded dockerfile string (Tiltfile's
        # dockerfile_contents = """FROM ...).  Match patterns like:
        #   FROM golang:1.25.7
        #   FROM golang:1.25.7-bookworm
        #   FROM golang:1.23.6-bullseye
        #   FROM golang:1.25.0
        # But NOT:
        #   FROM golang:1.25
        #   FROM golang:1.25-bookworm  (already correct)
        #   brew.registry.redhat.io/...  (not "golang:" prefix)
        #   registry.ci.openshift.org/... (not "golang:" prefix)
        #   quay.io/konveyor/builder:... (not "golang:" prefix)
        #   docker_build('.../golang:1.25.7', ...)  (not a FROM instruction)
        if grep -qE '(^|["[:space:]])[Ff][Rr][Oo][Mm][[:space:]].*\bgolang:[0-9]+\.[0-9]+\.[0-9]+' "$dockerfile"; then
            echo "=== Normalizing $dockerfile ==="

            # Strip patch version from golang: image references, only on
            # FROM instruction lines, so image names referenced elsewhere
            # (e.g. Tiltfile docker_build calls) are left untouched.
            # golang:1.25.7-bookworm  ->  golang:1.25-bookworm
            # golang:1.25.8           ->  golang:1.25
            # golang:1.23.6-bullseye  ->  golang:1.23-bullseye
            # golang:1.25.0           ->  golang:1.25
            sed -i -E '/(^|["[:space:]])[Ff][Rr][Oo][Mm][[:space:]]/s/(golang:[0-9]+\.[0-9]+)\.[0-9]+/\1/g' "$dockerfile"

            changed=1
        else
            echo "=== Skipping $dockerfile (no golang patch version found) ==="
        fi
    done < <(find . \( -name 'Dockerfile*' -o -name 'Containerfile*' -o -name '*.Dockerfile' -o -name 'Tiltfile*' \) -not -path '*/vendor/*' -print0)

    if [ "$changed" -eq 0 ]; then
        echo "=== No Dockerfiles needed normalization ==="
    fi

    stage_and_commit
}

sync_dockerfile_go_version() {
    # Sync the Go version in Dockerfiles/Containerfiles/Tiltfiles with go.mod.
    #
    # Problem: When go.mod is bumped to a new minor version (e.g. go 1.25 -> go 1.26),
    # the Dockerfiles still reference the old minor version (golang:1.25), causing
    # CI failures like:
    #   go: go.mod requires go >= 1.26.0 (running go 1.25.14; GOTOOLCHAIN=local)
    #
    # This runs AFTER normalize_dockerfiles (which strips patch versions) and updates
    # the minor version to match go.mod.

    if [ ! -f go.mod ]; then
        echo "=== No go.mod found, skipping Go version sync ==="
        return
    fi

    go_version=$(grep '^go ' go.mod | head -1 | awk '{print $2}')
    if [ -z "$go_version" ]; then
        echo "=== No go directive found in go.mod, skipping Go version sync ==="
        return
    fi

    # Strip any remaining patch version (e.g. 1.26.3 -> 1.26)
    go_minor=$(echo "$go_version" | sed -E 's/^([0-9]+\.[0-9]+)\.[0-9]+$/\1/')

    echo "Syncing Dockerfile Go versions to match go.mod (go $go_minor)"

    local changed=0

    while IFS= read -r -d '' dockerfile; do
        # Only process FROM lines that have a golang: image with a DIFFERENT
        # minor version than what go.mod declares.
        if grep -qE '(^|["[:space:]])[Ff][Rr][Oo][Mm][[:space:]].*\bgolang:[0-9]+\.[0-9]+' "$dockerfile"; then
            # Check if any FROM line has a golang version that differs from go.mod
            if grep -E '(^|["[:space:]])[Ff][Rr][Oo][Mm][[:space:]]' "$dockerfile" | grep -qv "golang:${go_minor}\b"; then
                if grep -E '(^|["[:space:]])[Ff][Rr][Oo][Mm][[:space:]]' "$dockerfile" | grep -q '\bgolang:[0-9]'; then
                    echo "=== Syncing $dockerfile to golang:$go_minor ==="
                    sed -i -E '/(^|["[:space:]])[Ff][Rr][Oo][Mm][[:space:]]/s/\bgolang:[0-9]+\.[0-9]+/golang:'"$go_minor"'/g' "$dockerfile"
                    changed=1
                fi
            fi
        fi
    done < <(find . \( -name 'Dockerfile*' -o -name 'Containerfile*' -o -name '*.Dockerfile' -o -name 'Tiltfile*' \) -not -path '*/vendor/*' -print0)

    if [ "$changed" -eq 0 ]; then
        echo "=== Dockerfile Go versions already match go.mod ==="
    fi

    stage_and_commit "UPSTREAM: <drop>: Sync Dockerfile Go version with go.mod"
}

normalize_dockerfiles
sync_dockerfile_go_version

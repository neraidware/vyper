#!/usr/bin/env bash
# Shared toolchain resolution. Sourced by build.sh and scripts/gate.sh, because
# both invoke the Odin compiler and both were broken by the same environment in
# the same way — one copy of a rule beats two that have to be kept in sync by
# hand (AGENTS.md: reuse through composition).
#
# Deliberately a sourced fragment, not an executable: it defines a function and
# runs nothing on its own.

# resolve_odin_root exports ODIN_ROOT pointing at the Odin tree that the
# compiler on PATH actually belongs to.
#
# The compiler needs ODIN_ROOT to find base/ and core/. A stale value in the
# environment fails the build with "Invalid ODIN_ROOT, directory does not
# exist" — an error that names a missing directory and never mentions that the
# value is pointing at a compiler that has since been replaced. That is not a
# hypothetical: a version manager taking over from a hand-installed compiler
# leaves the old path exported, so the tree behind it is simply gone.
#
# Validated rather than trusted, and when it is not an Odin tree, walk up from
# the odin on PATH until one is found. Detected rather than hardcoded, for the
# same reason build.sh detects mold: the install prefix is a per-host fact, and
# a prefix baked into a script is a bug waiting for the next host.
resolve_odin_root() {
	if [ -d "${ODIN_ROOT-}/base" ]; then
		return 0
	fi

	local odin_bin candidate
	odin_bin="$(command -v odin 2>/dev/null || true)"
	if [ -z "$odin_bin" ]; then
		echo "error: odin not found on PATH." >&2
		echo "  mise install provisions it; see .mise.toml." >&2
		return 1
	fi

	candidate="$(dirname "$odin_bin")"
	while [ ! -d "$candidate/base" ] && [ "$candidate" != "/" ]; do
		candidate="$(dirname "$candidate")"
	done
	if [ ! -d "$candidate/base" ]; then
		echo "error: no Odin tree found — looked for base/ at and above $odin_bin." >&2
		echo "  That directory has base/core/next; a bare compiler is not an Odin tree." >&2
		return 1
	fi

	echo "==> ODIN_ROOT '${ODIN_ROOT-}' is not an Odin tree; using $candidate" >&2
	ODIN_ROOT="$candidate"
	export ODIN_ROOT
}

# bash completion for system-optimize    -*- shell-script -*-
#
# Installed by install.sh into bash-completion's completions directory, or
# load it by hand:  source completions/system-optimize.bash
# A single-file build prints it:  source <(system-optimize --completion bash)
# zsh can use it too:  autoload -U bashcompinit && bashcompinit && source ...
#
# The option list is kept in step with --help by tests/unit/completion.bats.

# COMPREPLY=($(compgen ...)) is the standard idiom; words never contain spaces.
# shellcheck disable=SC2207

_so_opts="--dry-run --yes --status --undo --list-snapshots --only --skip
  --install-tools --force --verbose --quiet --no-color --color --timeout
  --config --log --no-log --self-update --source --branch --version --help
  --completion"
_so_steps="legacy sysctl io cpu limits trim tools"

_system_optimize() {
  local cur prev pfx="" base list
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  # --opt=value: bash splits it into "--opt" "=" "value" (= is in
  # COMP_WORDBREAKS); without that, it arrives as one word.
  if [ "$cur" = "=" ]; then
    cur=""
  elif [ "$prev" = "=" ] && [ "$COMP_CWORD" -ge 2 ]; then
    prev="${COMP_WORDS[COMP_CWORD-2]}"
  elif [[ "$cur" == --*=* ]]; then
    prev="${cur%%=*}"
    pfx="$prev="
    cur="${cur#*=}"
  fi

  case "$prev" in
    --color|--colour)
      COMPREPLY=($(compgen -P "$pfx" -W "auto always never" -- "$cur"))
      return 0 ;;
    --completion)
      COMPREPLY=($(compgen -P "$pfx" -W "bash zsh" -- "$cur"))
      return 0 ;;
    --only|--skip)
      # Comma separated: complete the last item.
      base=""
      list="$cur"
      if [[ "$list" == *,* ]]; then base="${list%,*},"; list="${list##*,}"; fi
      COMPREPLY=($(compgen -P "$pfx$base" -W "$_so_steps" -- "$list"))
      compopt -o nospace 2>/dev/null || true
      return 0 ;;
    --config|--log)
      compopt -o filenames 2>/dev/null || true
      COMPREPLY=($(compgen -f -- "$cur"))
      return 0 ;;
    --timeout|--source|--branch)
      return 0 ;;   # free-form values
  esac

  COMPREPLY=($(compgen -W "$_so_opts" -- "$cur"))
}

complete -F _system_optimize system-optimize

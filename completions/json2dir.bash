# bash completion for json2dir

_json2dir() {
    local cur prev opts
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="-o --out -n --dry-run -v --verbose --no-clobber -h --help -V --version"

    case "${prev}" in
        -o | --out)
            COMPREPLY=($(compgen -d -- "${cur}"))
            return 0
            ;;
    esac

    if [[ "${cur}" == -* ]]; then
        COMPREPLY=($(compgen -W "${opts}" -- "${cur}"))
        return 0
    fi

    COMPREPLY=($(compgen -f -X '!*.json' -- "${cur}"))
}
complete -F _json2dir json2dir

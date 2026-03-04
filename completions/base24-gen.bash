_base24_gen() {
    local cur prev
    _init_completion || return

    case "$prev" in
        --mode)
            COMPREPLY=($(compgen -W "dark light" -- "$cur"))
            return
            ;;
        --output)
            _filedir
            return
            ;;
        --name | --author)
            return
            ;;
    esac

    if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "--mode --name --author --output --preview --terminal --help" -- "$cur"))
        return
    fi

    _filedir '@(png|jpg|jpeg|bmp|gif|tga)'
}

complete -F _base24_gen base24-gen

#compdef base24-gen

_base24-gen() {
    _arguments -s \
        '--mode[Force dark or light mode]:mode:(dark light)' \
        '--name[Set colour scheme name]:name:' \
        '--author[Set author string]:author:' \
        '--output[Write YAML to file instead of stdout]:file:_files' \
        '--preview[Print ANSI colour swatches to stderr]' \
        '--terminal[Write OSC escape sequences to set terminal palette]' \
        '--help[Show usage information]' \
        ':image:_files -g "*.(png|jpg|jpeg|bmp|gif|tga)"'
}

_base24-gen "$@"

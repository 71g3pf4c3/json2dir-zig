# fish completion for json2dir

complete -c json2dir -s o -l out -d 'target directory (default: .)' -r -a '(__fish_complete_directories)'
complete -c json2dir -s n -l dry-run -d 'validate and print the plan; write nothing'
complete -c json2dir -s v -l verbose -d 'print one line per entry while applying'
complete -c json2dir -l no-clobber -d 'fail instead of replacing existing entries'
complete -c json2dir -s h -l help -d 'print usage and exit'
complete -c json2dir -s V -l version -d 'print version and exit'
complete -c json2dir -d 'JSON file' -r -a '*.json'

# bash completion for thysql. Print it with `thysql completion bash`:
#
#   eval "$(thysql completion bash)"                          # in ~/.bashrc
#   thysql completion bash > ~/.local/share/bash-completion/completions/thysql
#
# The candidates come from `thysql complete -- WORDS...`: one per line, then a last line
# ":<directive>", where 1 means no space after a candidate, 2 means also complete file
# names, and 4 means also complete directory names. Works with bash 3.2 (macOS /bin/bash).

# Sets `words` to the words before the cursor and `word` to the word under it. Bash 4 and
# later split a word at = and : (see COMP_WORDBREAKS), so those pieces are joined again.
_thysql_words() {
    local i piece joining=0
    words=()
    word=""
    for (( i = 1; i <= COMP_CWORD; i++ )); do
        piece=${COMP_WORDS[i]}
        if (( i == 1 )); then
            word=$piece
        elif (( joining )); then
            word=$word$piece
            joining=0
        elif [[ $piece == [=:] && $COMP_WORDBREAKS == *"$piece"* ]]; then
            word=$word$piece
            joining=1
        else
            words[${#words[@]}]=$word
            word=$piece
        fi
    done
}

_thysql() {
    local prog=${COMP_WORDS[0]} word i c len cut keep value line out n directive=0
    local -a words lines cands
    COMPREPLY=()
    (( COMP_CWORD > 0 )) || return 0
    _thysql_words

    # Bash replaces only the text after the last = or : in the word, when it breaks on it.
    # The candidates lose the part before that, so they match what bash replaces.
    len=0
    for (( i = 0; i < ${#word}; i++ )); do
        c=${word:i:1}
        if [[ $c == [=:] && $COMP_WORDBREAKS == *"$c"* ]]; then
            len=$(( i + 1 ))
        fi
    done
    cut=${word:0:len}

    # The value that a file or directory directive completes: after --name=, or after an
    # attached short option such as -S/tmp.
    case $word in
        --*=*) value=${word#*=} ;;
        -[!-]*) value=${word:2} ;;
        *) value=$word ;;
    esac
    keep=${word:0:$(( ${#word} - ${#value} ))}

    out=$("$prog" complete -- "$prog" "${words[@]}" "$word" </dev/null 2>/dev/null)
    while IFS= read -r line || [[ -n $line ]]; do
        lines[${#lines[@]}]=$line
    done <<< "$out"
    n=${#lines[@]}
    (( n > 0 )) || return 0

    directive=${lines[n-1]#:}
    case $directive in
        ''|*[!0-9]*) directive=0 ;;
    esac
    for (( i = 0; i < n - 1; i++ )); do
        if [[ -n ${lines[i]} ]]; then
            cands[${#cands[@]}]=${lines[i]}
        fi
    done

    if (( directive & 2 )); then
        while IFS= read -r line; do
            if [[ -n $line ]]; then cands[${#cands[@]}]=$keep$line; fi
        done <<< "$(compgen -f -- "$value")"
    fi
    if (( directive & 4 )); then
        while IFS= read -r line; do
            if [[ -n $line ]]; then cands[${#cands[@]}]=$keep$line/; fi
        done <<< "$(compgen -d -- "$value")"
    fi

    # A file or directory name, or a value like --ssl-ca=, takes no space after it.
    if (( directive & 5 )) && type compopt >/dev/null 2>&1; then
        compopt -o nospace
    fi

    for line in "${cands[@]}"; do
        COMPREPLY[${#COMPREPLY[@]}]=${line#"$cut"}
    done
}

complete -o default -F _thysql thysql

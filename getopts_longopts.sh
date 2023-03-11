#!/bin/bash -p
#
# Demonstrate converting long options to short options:
# Bashisms:
#  use associative arrays to translate from long <--> short option names
#  use indexed array to temporarily store args during long-to-short processing
#  (()) arithmetic evaluation
#
# NB: long-short processing applies to all cmdline arguments,
# even after the first positional argument, so if subcommands are used,
# the long-short processing needs to be done only once.

PROG=$(basename $0)

unset l2s
unset s2l
declare -A l2s
declare -A s2l
l2s['alpha']='a'  ; s2l['a']='alpha'
l2s['bravo']='b'  ; s2l['b']='bravo'
l2s['help']='h'   ; s2l['h']='help'
l2s['verbose']='v'; s2l['v']='verbose'

# Utility functions:
shortlong () { echo "-$1|--${s2l[$1]}"; }
longshort () { echo "-${l2s[$1]}|--$1"; }
die() { printf "\n$1\n" >&2; sub_help ${2-2}; }  # complain to STDERR and exit with error
needs_arg() {
  if [ -z "$OPTARG" ]; then
    die "Missing argument for $(shortlong $OPT) option"
  else
    case "${OPTARG}" in
      :|-*)
        die "Missing argument for $(shortlong $OPT) option"
        ;;
    esac
  fi
}
no_arg() { if [ -n "$OPTARG" ]; then die "No argument allowed for $(shortlong $OPT) option"; fi; }

function sub_help {
  cat >&2 <<EOF

Usage:  $PROG [options] <param1> [<params>...]

Options:
	option		arg	description

	-h|--help|help		Print help
	-v|--verbose		Increase verbosity (can be repeated)
	-a|--alpha		Boolean switch
	-b|--bravo	BOPT	Set bravo to BOPT (default: bravo_default)

Positional arguments:

	<param1>  		Positional argument 1

Long option arguments may be demarcated by either space or '='
EOF
  exit ${1:-0}
}

# Set optional argument defaults
verbose=0
alpha=0
bravo="bravo_default"

# Convert all recognized long options to short options:
PARAMS=()
for arg in "$@" ; do
  case "$arg" in
    help)         PARAMS+=("-h") ;;   # NB: 'help' positional arg turned into a -h option
    --?*)
      longopt="${arg#--}"
      longopt="${longopt%%=*}"
      shortopt="${l2s[$longopt]}"
      if [ -z "$shortopt" ] ; then
        # Pass through unrecognized options
        PARAMS+=("$arg")
      else
        # Check for '='-separated options
        optarg="${arg#--${longopt}}"
        optarg="${optarg#=}"
        PARAMS+=("-$shortopt")
        if [ -n "$optarg" ] ; then
          PARAMS+=("${optarg}")       # handle long option with '=' separator before optarg
        fi
      fi
      ;;
    *)            PARAMS+=("$arg") ;; # Pass through anything else
  esac
done

# Reset $@ to processed values
# Do this in a 'for' loop to ensure that individual arguments remain quoted if
# necessary
set --
for arg in "${PARAMS[@]}"; do
  set -- "$@" "$arg"
done

# Process all options as short arguments.
while getopts :hv-:ab: OPT; do
  case "$OPT" in
    h )    sub_help ;;
    v )    no_arg    && ((++verbose)) ;;
    a )    no_arg    && alpha=1 ;;
    b )    needs_arg && bravo="$OPTARG" ;;
    : )    die "Missing argument for $(shortlong $OPTARG) option" ;;
    - )    if [ -z "$OPTARG" ] ; then
             break # Stop processing remaining arguments
           else
             die "Unknown long option \'--${OPTARG}\'"
           fi ;;  # Stop processing optional arguments
    ? )    die "Unknown short option \'-${OPTARG}\'" ;;
  esac
done
shift $((OPTIND-1))             # remove parsed options and args from $@ list

if ! (($#)) ; then
  sub_help 2
fi

# Example verbose processing
if ((verbose)); then
  echo "Verbose true, verbosity level=$verbose"
fi

# Diagnostic output
printf "alpha=$alpha\nbravo=$bravo\nverbose=$verbose\n"
echo "Remaining args:"
printf "\t\"%s\"\n" "$@"

#!/bin/bash -p
PROG=$(basename $0)
verbose=0

usage () {
  cat >&2 <<EOF

Usage:  $PROG [options] <param1> [<params>...]

Options:
	option		arg	description

	-h|--help|help		Print help
	-v|--verbose		Increase verbosity (can be repeated)
	-a|--alpha		Boolean switch
	-b|--bravo[=]	BOPT	Set bravo to BOPT (default: bravo_default)
	--charlie		Charlie switch, no short option

Positional arguments:

	<param1>  		Positional argument 1

Long option arguments may be demarcated by either space or '='
EOF
  exit ${1:-0}
}

die () { printf "\n$1\n" >&2; usage ${2:-1}; }  # complain to STDERR and exit with error

# Not quite a drop-in replacement for getopts.
# Modeled after https://github.com/UrsaDK/getopts_long, but pulled standard
# error handling inside, and handle option-terminating '--' differently
get_options () {
  : "${1:?$0: Missing required parameter -- long optspec}"
  : "${2:?$0: Missing required parameter -- variable name}"

  local optspec_short="${1%% *}-:"
  local optspec_long="${1#* }"
  local optvar="${2}"
  shift 2
  # Ensure there's a leading colon on the short optspec:
  [[ "${optspec_short:0:1}" == ':' ]] || optspec_short=":${optspec_short}"

  # Ensure there are commandline arguments to parse
  (($#)) || die "$(basename $0): NO CMDLINE ARGUMENTS TO PARSE" 127

  # Halt option processing immediately if we hit a double-dash
  unset OPTARG
  : ${OPTIND:-1}
  if [[ "${!OPTIND}" == "--" ]] ; then
    ((++OPTIND))
    return 1
  fi

  builtin getopts "${optspec_short}" "${optvar}" "$@" || return 1

  # Handle builtin getopts short-option errors here:
  case "${!optvar}" in
    ':') die "MISSING ARGUMENT for \'-${OPTARG}\' option" 1 ;;
    '?') die "UNKNOWN OPTION \'-${OPTARG}\'"              2 ;;
    ?)   [[ "${OPTARG}" != "--" ]] || \
         die "MISSING ARGUMENT for \'-${!optvar}\' option" 3 ;; 
  esac

  # If there was a non-hyphen short option found, without an error, return true
  [[ "${!optvar}" == '-' ]] || return 0

  # Set $optvar to the current OPTARG stripped of anything after the first '=':
  printf -v "${optvar}" "%s" "${OPTARG%%=*}"

  if [[ "${optspec_long}" =~ (^|[[:space:]])${!optvar}:([[:space:]]|$) ]]; then
    # Found option matches a long option requiring an argument:
    OPTARG="${OPTARG#${!optvar}}";   # Strip leading option name
    OPTARG="${OPTARG#=}";            # Strip first '=', if found

    # NB: we allow '--<longopt>=--' in the rare case that you actually want an
    # arg-requiring option to be set to double-dash.
    #
    # But '-<shortopt> --' and '--<longopt> --' are errors for arg-requiring
    # options.

    if [[ -z "${OPTARG}" ]]; then
      # Missing argument, so check the next space-separated argument and increment OPTIND
      OPTARG="${!OPTIND}" && ((++OPTIND))
      # Error out if space-separated argument happens to be a double-dash
      [[ "${OPTARG}" != "--" ]] || die "MISSING ARGUMENT for \'--${!optvar}\' option" 4

      # Return true unless there's no argument provided
      [[ -z "${OPTARG}" ]] || return 0
      die "MISSING ARGUMENT for \'--${!optvar}\' option" 5
    fi
  elif [[ "${optspec_long}" =~ (^|[[:space:]])${!optvar}([[:space:]]|$) ]]; then
    # option matches, but no argument required, so unset OPTARG
    unset OPTARG
  else
    # The long option wasn't recognized as part of $optspec_long
    die "UNKNOWN OPTION \'--${!optvar}\'" 6
  fi
}

# Set optional argument defaults
alpha=0
bravo="bravo_default"
charlie=0

# ------------------------------------------------------------------------------
# GET_OPTIONS EXAMPLE
# ------------------------------------------------------------------------------
# Usage:
# get_options '<shortopts><space><longopts, separated by spaces>' <optvar> "$@"
#
# Leading colon on shortopts is optional
# ------------------------------------------------------------------------------
OPTIND=1;  # Optional here, required in subcommands
while get_options 'hvab: alpha bravo: charlie' OPT "$@" ; do
  case "$OPT" in
    h|help   ) usage           ;; # E.g., help option
    v|verbose) ((++verbose))   ;; # E.g., an incrementing option
    a|alpha  ) alpha=1         ;; # E.g., non-arg-requiring option
    b|bravo  ) bravo="$OPTARG" ;; # E.g., argument-requiring option
    charlie  ) charlie=1       ;; # E.g., long-option-only
  esac
done
shift $((OPTIND-1))    # remove parsed options and args from $@ list

# Ensure that at least one parameter is provided, for this example
(($#)) || die "MISSING REQUIRED PARAMETER AFTER OPTIONS" 7

# Handle getting 'help' as a parameter, without leading dashes
(($#)) && case "$1" in help) usage ;; esac

# Example verbose processing
((verbose)) && echo "Verbose true, verbosity level=$verbose"

# Diagnostic output
printf "alpha=$alpha\nbravo=$bravo\ncharlie=$charlie\nverbose=$verbose\n"
echo "Remaining args:"
printf "\t\"%s\"\n" "$@"

#!/bin/bash -p
#
# Script to set up reciprocal SSH key-pairs between the
# local system and a specified remote system.
#
# Simplify perms:  turn off group and other permissions by default:
# Start at user home directory
umask 077
cd                              # default is to cd $HOME
: ${HOME:=$PWD}                 # set $HOME to Posix standard $PWD if not set
PROG=$(basename $0)

# move directory to the front of the path:
# This also removes duplicates in PATH
prepend_path () {
  (($# == 1)) || return 1
  NEWPATH="$1"
  for dir in $(echo $PATH | tr ':' ' '); do
    echo "$NEWPATH" | tr ':' '\n' | grep "^${dir}$" > /dev/null 2>&1 || NEWPATH="${NEWPATH}:${dir}"
  done
  export PATH="$NEWPATH"
}

# Standardize path:
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

for dir in \
  /usr/local/buildtools/java/jdk/bin \
  /usr/lib/google-golang/bin \
  $HOME/bin \
  $HOME/.local/bin \
  ; do
  prepend_path "$dir"
done

die() { printf "\n$1\n" >&2; usage ${2:-1}; }  # complain to STDERR and exit with error

usage () {
  cat >&2 <<EOF

Usage:  $PROG [options] <[REMOTE_USER@]REMOTE_HOST|LOGFILE> [PROJECT]

Options:

	(option)		(arg)	(description)

	-h|--help|help			Print help
	-v|--verbose			Increase verbosity (can be repeated)
	-g|--group		GROUP	GCE group (default: compute)
	-n|--nickname		NICK	Optional nickname for remote host
	-p|--project		PROJECT	Gcloud project, if not able to infer from env or gcloud
	-u|--user		USER	Remote user, if not able to infer from 'whoami' on remote host

Positional arguments:

	[REMOTE_USER@]REMOTE_HOST	Remote host, can be a prefix,
					optional remote user can be supplied before '@'-sign
					here or via -u option.
					
	LOGFILE				Alternatively, the first positional argument can be a
					logfile containing the output of the terraform deploy command.
					
	PROJECT				Gcloud project, can be supplied as optional second positional arg,
					via -p option, via PROJECT env variable, or by searching
					for current default gcloud project


Long option arguments may be demarcated by either space or '='
EOF
  exit ${1:-0}
}

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
verbose=0
group="compute"
unset project
unset nickname
unset REMOTE_USER

# Process options in short or long form:
while get_options 'hvg:n:p:u: help verbose group: nickname: project: user:' OPT "$@"; do
  case "$OPT" in
    h|help    ) usage                 ;;
    v|verbose ) ((++verbose))         ;;
    g|group   ) group="$OPTARG"       ;;
    n|nickname) nickname="$OPTARG"    ;;
    p|project ) project="$OPTARG"     ;;
    u|user    ) REMOTE_USER="$OPTARG" ;;
  esac
done
shift $((OPTIND-1)) # remove parsed options and args from $@ list

# ----------------------------------------------------------------------
# Argument parsing complete
# ----------------------------------------------------------------------
# Start actual work:
# ----------------------------------------------------------------------

# Handle 'help'
if (($#)) ; then
  case "$1" in
    help) usage ;;
  esac
fi

# See if we can infer a Terraform deploy logfile from the first argument, if present,
# or from any *deploy*.log files in the current directory.
if ! test -v logfile ; then
  if (( $# > 0 )) ; then
    if [ -f "$1" ] ; then
      if grep name_prefix $1 1>/dev/null 2>&1 ; then
        export logfile=$1
      fi
    fi
  else
    testlogfile="$(ls -1 -rt *deploy*.log 2>/dev/null| tail -1)"
    if [ -n "$testlogfile" ] ; then
      if [ -r "$testlogfile" ] ; then
        if grep name_prefix "$testlogfile" 1>/dev/null 2>&1 ; then
          export logfile="$testlogfile"
        fi
      fi
    fi
  fi
else
  if [ -f "$logfile" ] ; then
    if ! grep name_prefix $logfile 1>/dev/null 2>&1 ; then
      die "name_prefix not found in logfile $logfile"
    fi
  else
    die "logfile $logfile not readable"
  fi
fi

if test -v logfile && ((verbose > 1)) ; then
  echo "logfile set to $logfile"
fi

if ! test -v logfile ; then
  (( $# )) || die "No logfile or remote host provided"

  # user@host syntax overrides -u argument
  REMOTE_HOST="$1"
  case "$REMOTE_HOST" in
     *@*)
        REMOTE_USER=${REMOTE_HOST%@*}
        REMOTE_HOST=${REMOTE_HOST#*@}
        ;;
  esac
  shift
fi

if (( $# > 0 )) ; then
  project="$1"
  ((verbose)) && echo "project set to $project using commandline argument"
else
  if ! test -v project ; then
    if test -v PROJECT ; then
      ((verbose > 1)) && echo "Setting project from \$PROJECT"
      project="$PROJECT"
    elif gcloud config list --format='text(core.project)' >/dev/null 2>/dev/null ; then
      ((verbose > 1)) && echo "Setting project from gcloud config list check"
      project="$(gcloud config list --format='text(core.project)' 2>/dev/null | awk '{print $2}')"
    else
      die "No project specified"
    fi
  fi
fi
export project
((verbose > 1)) && echo "project = $project"

# Ensure ~/.ssh/, and ~/.ssh/config.d/ exist
mkdir -p ~/.ssh/config.d
chmod -R go-rwx ~/.ssh

test -v REMOTE_USER && export REMOTE_USER
export group

# The unit 8 and unit 9 redirects are to work around the problem of doing an
# stdin-greedy ssh command in the inner loop.
#
# Use either $logfile or positional argument REMOTE_HOST to read the remote
# host, piping the output through unit 8
#
if test -v logfile && test -f "$logfile" ; then
  exec 8< <(grep name_prefix "$logfile" | grep -v known | egrep -o '[^"]+-(login|controller)')
else
  exec 8< <(echo "$REMOTE_HOST")
fi

# Keep track of created files
configlist="$HOME/.ssh/gcp_ssh_setup_configs.txt"
scriptlist="$HOME/.ssh/gcp_ssh_setup_scripts.txt"
: > $configlist
: > $scriptlist

# Then read the variable via unit 8
while read -u8 REMOTE_HOST ; do
  # Workaround the problem of doing an ssh command within a while
  # loop (because ssh expects stdin greedily)
  #
  # Save the gcloud list output to an on-the-fly named pipe, but
  # redirect it through unit 9
  exec 9< <(gcloud $group instances list --project=$project | \
            egrep "$REMOTE_HOST" | \
            awk '{print $1, $2}')

  # then read the while loop from unit 9
  while read -u9 hka zone ; do
    if ((verbose > 1)) ; then
      echo "hka: $hka, zone: $zone"
    fi

    gcloud_ssh="gcloud $group ssh $hka --project=$project --zone=$zone --tunnel-through-iap"

    ssh_filename="$HOME/.ssh/ssh_${hka}.sh"
    printf "#!/bin/sh\n$gcloud_ssh \${1+\$@}\n" > $ssh_filename
    chmod +x $ssh_filename

    echo $ssh_filename >> $scriptlist

    if ((verbose>1)) ; then
      echo "Running '$ssh_filename --command=whoami' to set up keys for $hka on this host"
      echo "The contents of $ssh_filename are"
      sed -re 's/^/\t/' $ssh_filename
    fi

    # This is the problematic command requiring stdin redirects above.
    # The -n ssh flag might get around it, but it doesn't hurt to be safe.
    remote_user="$(eval $ssh_filename --ssh-flag=-n --command=whoami 2>/dev/null)"
    ((verbose > 1)) && echo "remote_user set to $remote_user"

    if test -v REMOTE_USER ; then
      remote_user="$REMOTE_USER"
    fi
    ((verbose > 1)) && printf "\n\tRemote user = $remote_user\n"

    hostalias="$hka"
    if test -v nickname ; then
      hostalias="$nickname"
      if [ "$nickname" != "$hka" ] ; then
        hostalias="$hostalias $hka"
      fi
    else
      case "$hka" in
        *-login-*)
          prelogin="${hka%%-login-*}"
          hostalias="${prelogin}-login $hka"
          ;;
      esac
    fi

    ssh_config_filename="$HOME/.ssh/config.d/${hka}"
    cat > $ssh_config_filename <<-EOF
	Host $hostalias
	   User				${remote_user}
	   HostKeyAlias			$hka
	   Hostname			$hka.$project.$zone.${group// /_}.gcp
	
	EOF

    if ((verbose > 1)) ; then
      cat <<-EOF
	-----------------------------------
	This host has ssh keys set up to use ssh from the commandline, and ssh aliases
	have been saved to files in the ~/.ssh/config.d/ directory.
	
	Verify that the line 'Include "~/.ssh/config.d/*"' is at the top of ~/.ssh/config .
	
	The lines that have been saved into $ssh_config_filename are
	
	EOF
      sed -re 's/^/\t/' $ssh_config_filename
    fi
    echo $ssh_config_filename >> $configlist
  done
done

gcp_group_filename="$HOME/.ssh/config.d/zzz_match_host_${group// /_}_gcp"

if ((verbose > 1)) ; then
  echo "------"
  cat <<-EOF
	The ssh config stanzas in config.d rely on the stanza saved to $gcp_group_filename being found
	later in ~/.ssh/config.d/*. Its contents look like this:
	
	EOF
fi

cat >"$gcp_group_filename" <<-EOF
	# Pseudo-host format for GCP ${group} VM instances:
	#    instance.project.zone.${group// /_}.gcp
	#
	# Host short-name instance-name
	#     User           ldap_google_com
	#     HostKeyAlias   instance-name
	#     HostName       instance-name.project.zone.${group// /_}.gcp
	#
	# Add additional stanzas for different gcloud groups
	#
	# Be sure you set the HostKeyAlias to the instance name.
	Match Host *.*.*.${group// /_}.gcp
	    IdentityFile                ~/.ssh/google_${group// /_}_engine
	    UserKnownHostsFile          ~/.ssh/google_${group// /_}_known_hosts
	    IdentitiesOnly              yes
	    CheckHostIP                 no
	    ProxyUseFdpass              no
	    ProxyCommand                gcloud ${group} start-iap-tunnel %k %p --listen-on-stdin --project=\$(echo %h| cut -d. -f2) --zone=\$(echo %h| cut -d. -f3)
	
	EOF

if ((verbose > 1)) ; then
  sed -re 's/^/\t/' $gcp_group_filename
fi

echo $gcp_group_filename >> $configlist

# Ensure 'Include ~/.ssh/config.d/*' is at the top of ~/.ssh/config:
if test -s $HOME/.ssh/config ; then
  ((verbose > 1)) && echo '~/.ssh/config exists'
  if grep '^Include "\~/.ssh/config.d/\*"' $HOME/.ssh/config >/dev/null 2>&1 ; then
    ((verbose > 1)) && echo "~/.ssh/config is already set up"
  else
    /bin/cp -f $HOME/.ssh/config $HOME/.ssh/config~
    printf 'Include "~/.ssh/config.d/*"\n\n' | cat - $HOME/.ssh/config~ > $HOME/.ssh/config
  fi
else
  printf 'Include "~/.ssh/config.d/*"\n\n' > $HOME/.ssh/config
fi
chmod -R go-rwx $HOME/.ssh

if ((verbose)) ; then
  printf "\nSSH scripts created by this utility:\n\n"
  xargs ls -l < $scriptlist

  printf "\nSSH config stanzas created by this utility:\n\n"
  xargs ls -l < $configlist

  printf "\nContents of the config stanzas, as they would be included by ~/.ssh/config:\n\n"
  xargs cat < $configlist

  printf "\nThe first few lines of ~/.ssh/config are now:\n\n"
  head ~/.ssh/config | nl
fi

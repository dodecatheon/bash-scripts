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

# Standardize path:
#
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# Prepend paths
for dir in \
  /usr/local/buildtools/java/jdk/bin \
  /usr/lib/google-golang/bin \
  $HOME/bin \
  $HOME/.local/bin \
  ; do
  if test -d $dir ; then
    export PATH="$dir:$PATH"
  fi
done

function leading_tab_fmt {
  _us="___"
  echo "$1" | \
    sed -e 's/  / /g' | \
    printf "${_us}%s\n" | \
    fmt -p"${_us}" | \
    sed -re "s//\t/"
}

unset l2s
unset s2l
declare -A l2s
declare -A s2l
l2s['group']='g'       ; s2l['g']='group'
l2s['nickname']='n'    ; s2l['n']='nickname'
l2s['project']='p'     ; s2l['p']='project'
l2s['remote-user']='u' ; s2l['u']='remote-user'
l2s['help']='h'        ; s2l['h']='help'
l2s['verbose']='v'     ; s2l['v']='verbose'

# Utility functions:
shortlong () { echo "-$1|--${s2l[$1]}"; }
longshort () { echo "-${l2s[$1]}|--$1"; }
die() { printf "\n$1\n" >&2; usage ${2-2}; }  # complain to STDERR and exit with error
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

usage () {
  cat >&2 <<EOF

Usage:  $PROG [options] <[REMOTE_USER@]REMOTE_HOST|LOGFILE> [PROJECT]

Options:

	-h|--help|help			Print help
	-v|--verbose			Increase verbosity (can be repeated)
        -g GROUP|--group=GROUP		GCE group (default: compute)
        -n NICK|--nicknamel=NICK	Optional nickname for remote host
        -p PROJECT|--project=PROJECT	Gcloud project, if not able to infer from env or gcloud
        -u USER|--remote-user=USER	Remote user, if not able to infer from 'whoami' on remote host

Positional arguments:

	[REMOTE_USER@]REMOTE_HOST	Remote host, can be a prefix,
					optional remote user can be supplied here or via -u option.
					
	LOGFILE				Alternatively, the first positional argument can be a
					logfile containing the output of the terraform deploy command.
					
	PROJECT				Gcloud project, can be supplied as optional second positional arg,
					via -p option, via PROJECT env variable, or by searching
					for current default gcloud project


Long option arguments may be demarcated by either space or '='
EOF
  exit ${1-0}
}

# Convert all recognized long options to short options:
PARAMS=()             # Use Bash indexed array to store arguments during processing
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


# Set optional argument defaults
verbose=0
group="compute"
unset project
unset nickname
unset REMOTE_USER

# Process all options as short arguments.
while getopts :hv-:g:l:p:r:s: OPT; do
  case "$OPT" in
    h )    usage ;;
    v )    no_arg    && ((++verbose)) ;;
    g )    needs_arg && group="$OPTARG" ;;
    n )    needs_arg && nickname="$OPTARG" ;;
    p )    needs_arg && project="$OPTARG" ;;
    u )    needs_arg && REMOTE_USER="$OPTARG" ;;
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
    testlogfile="$(ls -1 -rt *deploy*.log | tail -1)"
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
	   Hostname			$hka.$project.$zone.${group}.gcp
	
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

gcp_group_filename="$HOME/.ssh/config.d/zzz_match_host_${group}_gcp"

if ((verbose > 1)) ; then
  echo "------"
  cat <<-EOF
	The ssh config stanzas in config.d rely on the stanza saved to $gcp_group_filename being found
	later in ~/.ssh/config.d/*. Its contents look like this:
	
	EOF
fi

cat >"$gcp_group_filename" <<-EOF
	# Pseudo-host format for GCP ${group} VM instances:
	#    instance.project.zone.${group}.gcp
	#
	# Host short-name instance-name
	#     User           ldap_google_com
	#     HostKeyAlias   instance-name
	#     HostName       instance-name.project.zone.${group}.gcp
	#
	# Add additional stanzas for different gcloud groups
	#
	# Be sure you set the HostKeyAlias to the instance name.
	Match Host *.*.*.${group}.gcp
	    IdentityFile                ~/.ssh/google_${group}_engine
	    UserKnownHostsFile          ~/.ssh/google_${group}_known_hosts
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

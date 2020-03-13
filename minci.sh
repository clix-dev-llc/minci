#! /bin/sh

# Usage:
# minci.sh [-fnv] [repo...]
# Use ~/.minci or /etc/minci for configuration, whichever comes first.

MAKE="make"
API_SECRET=
DEP_BINS="mandoc openssl git curl"
NOOP=
LOG=
VERBOSE=
API_KEY=
SERVER=
STAGING="$HOME/.local/cache/minci"
CONFIG=
CONFIG_LOCAL="$HOME/.minci"
CONFIG_GLOBAL="/etc/minci"
PROGNAME="$0"
FORCE=

msg()
{
	echo "$PROGNAME: $(date +"%F %T"): $@"
}

fatal()
{
	echo "$PROGNAME: fatal: $@" 1>&2
	exit 1
}

debug()
{
	[ -z "${VERBOSE}" ] || echo "$PROGNAME: $(date +"%F %T"): $@"
}

run()
{
	debug "$1: $2"
	if [ -z "$NOOP" ]
	then
		echo "$PROGNAME: $1: $2" 1>&3
		$1 1>&3 2>&3 || return 1
	fi
	return 0
}

args=$(getopt fnv $*)
if [ $? -ne 0 ]
then
	echo "usage: $PROGNAME [-fnv] [repo ...]" 1>&2
	exit 1
fi

set -- $args

while [ $# -ne 0 ]
do
	case "$1"
	in
		-n)
			NOOP=1 ; shift ;;
		-f)
			FORCE=1 ; shift ;;
		-v)
			VERBOSE=1 ; shift ;;
		--)
			shift ; break ;;
        esac
done

# Start with the local then global configuration.
# Require at least one of them.

if [ ! -r "$CONFIG_LOCAL" ]
then
	if [ ! -r "$CONFIG_GLOBAL" ]
	then
		fatal "$PROGNAME: no config found"
	fi
	CONFIG="$CONFIG_GLOBAL"
else
	CONFIG="$CONFIG_LOCAL"
fi
debug "using config: $CONFIG"

# Read the API secret from the configuration.

while read -r ln
do
	bsdmake="$(echo "$ln" | sed -n 's!^[ ]*bsdmake[ ]*=[ ]*!!p')"
	[ -z "$bsdmake" ] && continue
	MAKE="$bsdmake"
done < "$CONFIG"

DEP_BINS="$DEP_BINS $MAKE"

# Read the API secret from the configuration.

while read -r ln
do
	api_secret="$(echo "$ln" | sed -n 's!^[ ]*apisecret[ ]*=[ ]*!!p')"
	[ -z "$api_secret" ] && continue
	API_SECRET="$api_secret"
done < "$CONFIG"
if [ -z "$API_SECRET" ]
then
	fatal "no API secret specified"
fi

# Read the API key from the configuration.

while read -r ln
do
	api_key="$(echo "$ln" | sed -n 's!^[ ]*apikey[ ]*=[ ]*!!p')"
	[ -z "$api_key" ] && continue
	API_KEY="$api_key"
done < "$CONFIG"
if [ -z "$API_KEY" ]
then
	fatal "no API key specified"
fi

# Read the server from the configuration.

while read -r ln
do
	server="$(echo "$ln" | sed -n 's!^[ ]*server[ ]*=[ ]*!!p')"
	[ -z "$server" ] && continue
	SERVER="$server"
done < "$CONFIG"
if [ -z "$SERVER" ]
then
	fatal "no server specified"
fi

debug "using API key: $API_KEY"
debug "using API secret: $API_SECRET"
debug "using server: $SERVER"

for dep in $DEP_BINS
do
	debug "$0: check binary dependency: $dep"
	which "$dep" 2>/dev/null 1>&2
	if [ $? -ne 0 ]
	then
		fatal "binary dep not in PATH: $dep"
	fi
done

# Check or create where we'll put our repositories.

if [ ! -d "$STAGING" -a -z "$NOOP" ]
then
	mkdir -p "$STAGING"
	if [ $? -ne 0 ]
	then
		fatal "could not create: $STAGING"
	fi
	debug "created: $STAGING"
fi

# Process each repository line.

while read -r ln
do
	repo="$(echo $ln | sed -n 's!^[ ]*repo[ ]*=[ ]*!!p')"
	[ -z "$repo" ] && continue
	reponame="$(echo $repo | sed -e 's!.*/!!' -e 's!\.git$!!')"
	if [ -z "$reponame" ]
	then
		fatal "malformed repo: $repo"
	fi

	# Iterate through the command-line arguments, only if specified,
	# to see if we want to run this.

	if [ $# -gt 0 ]
	then
		for prog in "$@"
		do
			if [ "$prog" = "$reponame" ]
			then
				prog=""
				break
			fi
		done
		if [ -n "$prog" ]
		then
			debug "ignoring: $reponame"
			continue
		fi
	fi

	# Get ready for actual processing.
	# Now errors without || are fatal.

	set -e

	debug "$repo: $reponame"

	[ -n "$NOOP" ] || exec 3>/tmp/minci.log
	[ -n "$NOOP" ] || cd "$STAGING"

	# Set all of our times to zero.
	# If a time is non-zero when we send our report, that means that
	# we've finished a phase.

	TIME_start=0
	TIME_env=0
        TIME_depend=0
        TIME_build=0
        TIME_test=0
        TIME_install=0
        TIME_distcheck=0

	TIME_start=$(date +%s)

	# This is wrapped in an infinite loop so we can just use `break`
	# to come out of error situations and still send the report.

	while :
	do
		head=""
		nhead=""

		# If we have a repository already, update and clean it
		# out; otherwise, clone it afresh.
		# Keep track of the FETCH_HEAD last commit.

		if [ -d "$reponame" ]
		then
			if [ -z "$NOOP" ]
			then
				cd "$reponame"
				head=$(cut -f1 .git/FETCH_HEAD 2>/dev/null) || head=""
			fi
			run "git fetch origin" "$reponame" || break
			run "git reset --hard origin/master" "$reponame" || break
			run "git clean -fdx" "$reponame" || break
			if [ -z "$NOOP" ]
			then
				nhead=$(cut -f1 .git/FETCH_HEAD) || nhead=""
			fi
		else
			head=""
			nhead=""
			run "git clone $repo" "$reponame" || break
			if [ -z "$NOOP" ]
			then
				cd "$reponame"
			fi
		fi

		# If the FETCH_HEAD commit doesn't change when we freshen the
		# repository, then doing re-test it unless -f was passed.

		if [ -z "$FORCE" -a -n "$head" -a \
		     -n "$nhead" -a "$head" = "$nhead" ]
		then
			debug "repository is fresh: $reponame"
			TIME_start=0
			break
		fi

		TIME_env=$(date +%s)

		run "./configure PREFIX=build" "$reponame" || break
		TIME_depend=$(date +%s)

		run "${MAKE}" "$reponame" || break
		TIME_build=$(date +%s)

		run "${MAKE} regress" "$reponame" || break
		TIME_test=$(date +%s)

		run "${MAKE} install" "$reponame" || break
		TIME_install=$(date +%s)

		run "${MAKE} distcheck" "$reponame" || break
		TIME_distcheck=$(date +%s)
		break
	done

	# Stop reporting to fd-3 and remask errors.
	# Our house-keeping can now fail without killing us.

	[ -n "$NOOP" ] || exec 3>&-
	set +e

	if [ $TIME_start -eq 0 ]
	then
		msg "ignoring: $reponame"
		[ -n "$NOOP" ] || rm -f /tmp/minci.log
		continue
	fi

	if [ $TIME_distcheck -eq 0 ]
	then
		msg "failure: $reponame"
	else
		msg "success: $reponame"
	fi

	debug "computing signature"

	UNAME_M=$(uname -m | sed -e 's!^[ ]*!!g' -e 's![ ]*$!!g')
	UNAME_N=$(uname -n | sed -e 's!^[ ]*!!g' -e 's![ ]*$!!g')
	UNAME_R=$(uname -r | sed -e 's!^[ ]*!!g' -e 's![ ]*$!!g')
	UNAME_S=$(uname -s | sed -e 's!^[ ]*!!g' -e 's![ ]*$!!g')
	UNAME_V=$(uname -v | sed -e 's!^[ ]*!!g' -e 's![ ]*$!!g')

	# Create the signature for this entry.
	# It consists of all the MD5 hash of all arguments in
	# alphabetical order (by key), with the report-log (or /dev/null
	# if there's no need to report) being replaced by its MD5 hash.

	QUERY="project-name=${reponame}"
	QUERY="${QUERY}&report-build=${TIME_build}"
	QUERY="${QUERY}&report-distcheck=${TIME_distcheck}"
	QUERY="${QUERY}&report-env=${TIME_env}"
	QUERY="${QUERY}&report-depend=${TIME_depend}"
	QUERY="${QUERY}&report-install=${TIME_install}"
	if [ $TIME_distcheck -eq 0 ]
	then
		hashfile="/tmp/minci.log"
	else
		hashfile="/dev/null"
	fi
	hash="$(openssl dgst -md5 -hex $hashfile | sed 's!^[^=]*= !!')"
	QUERY="${QUERY}&report-log=$hash"
	QUERY="${QUERY}&report-start=${TIME_start}"
	QUERY="${QUERY}&report-test=${TIME_test}"
	QUERY="${QUERY}&report-unamem=${UNAME_M}"
	QUERY="${QUERY}&report-unamen=${UNAME_N}"
	QUERY="${QUERY}&report-unamer=${UNAME_R}"
	QUERY="${QUERY}&report-unames=${UNAME_S}"
	QUERY="${QUERY}&report-unamev=${UNAME_V}"
	QUERY="${QUERY}&user-apisecret=${API_SECRET}"

	# Signature is the MD5 of ordered parameters and including our
	# API secret.
	# The server will perform the same steps.

	SIGNATURE=$(printf "%s" "$QUERY" | openssl dgst -md5 -hex | sed 's!^[^=]*= !!')

	# Now actually send the report.
	# It includes the signature and optionally the build log (only
	# if we didn't get to the end).

	debug "sending report: $SERVER"

	REPORT_LOG=
	if [ $TIME_distcheck -eq 0 ]
	then
		REPORT_LOG="-F report-log=</tmp/minci.log"
	else
		REPORT_LOG="-F report-log="
	fi

	if [ -z "$NOOP" ]
	then
		curl -sS ${REPORT_LOG} \
		     -F "project-name=${reponame}" \
		     -F "report-start=${TIME_start}" \
		     -F "report-env=${TIME_env}" \
		     -F "report-depend=${TIME_depend}" \
		     -F "report-build=${TIME_build}" \
		     -F "report-test=${TIME_test}" \
		     -F "report-install=${TIME_install}" \
		     -F "report-distcheck=${TIME_distcheck}" \
		     -F "report-unamem=${UNAME_M}" \
		     -F "report-unamen=${UNAME_N}" \
		     -F "report-unamer=${UNAME_R}" \
		     -F "report-unames=${UNAME_S}" \
		     -F "report-unamev=${UNAME_V}" \
		     -F "user-apikey=${API_KEY}" \
		     -F "signature=${SIGNATURE}" \
		     "${SERVER}"
		rm -f /tmp/minci.log
	fi
done < "$CONFIG"

exit 0

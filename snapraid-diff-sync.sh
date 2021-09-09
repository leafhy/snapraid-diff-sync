#!/bin/bash
########################################################################
#
# https://github.com/auanasgheps/snapraid-aio-script
# https://zackreed.me/snapraid-split-parity-sync-script
#
########################################################################

######################  USER CONFIGURATION  ######################

# address where the output of the jobs will be emailed to.
EMAIL_ADDRESS="root"

# Set the threshold of deleted files to stop the sync job from running. NOTE
# that depending on how active your filesystem is being used, a low number here
# may result in your parity info being out of sync often and/or you having to
# do lots of manual syncing.
DEL_THRESHOLD=50
UP_THRESHOLD=50

# Set number of warnings before we force a sync job. This option comes in handy
# when you cannot be bothered to manually start a sync job when DEL_THRESHOLD
# is breached due to false alarm. Set to 0 to ALWAYS force a sync (i.e. ignore
# the delete threshold above) Set to -1 to NEVER force a sync (i.e. need to
# manual sync if delete threshold is breached).
SYNC_WARN_THRESHOLD=-1

# Set percentage of array to scrub if it is in sync. i.e. 0 to disable and 100
# to scrub the full array in one go WARNING - depending on size of your array,
# setting to 100 will take a very long time!
SCRUB_PERCENT=0
SCRUB_AGE=10

# Set number of script runs before running a scrub. Use this option if you
# don't want to scrub the array every time.
# Set to 0 to disable this option and run scrub every time.
SCRUB_DELAYED_RUN=0

# Prehash Data To avoid the risk of a latent hardware issue, you can enable the
# "pre-hash" mode and have all the data read two times to ensure its integrity.
# This option also verifies the files moved inside the array, to ensure that
# the move operation went successfully, and in case to block the sync and to
# allow to run a fix operation. 1 to enable, any other values to disable.
PREHASH=0

# Set the option to log SMART info. 1 to enable, any other value to disable.
SMART_LOG=1

# Set verbosity of the email output. TOUCH and DIFF outputs will be kept in the
# email, producing a potentially huge email. Keep this disabled for optimal
# reading You can always check TOUCH and DIFF outputs using the TMP file. 1 to
# enable, any other values to disable.
VERBOSITY=0

# Set if disk spindown should be performed. Depending on your system, this may
# not work. 1 to enable, any other values to disable.
SPINDOWN=0

# Run snapraid status command to show array general information. Be aware the
# HTML output is pretty broken.
SNAP_STATUS=1

####################### SYSTEM CONFIGURATION #######################

# location of the snapraid binary
SNAPRAID_BIN="/usr/sbin/snapraid"
# location of the mail program binary (sendmail is an symbolic link to femtomail)
MAIL_BIN="/usr/sbin/sendmail"

# Init variables
CHK_FAIL=0
DO_SYNC=0
EMAIL_SUBJECT_PREFIX="(SnapRAID on $(hostname))"
CURRENT_DIR=$(dirname "${0}")
SYNC_WARN_FILE="$CURRENT_DIR/snapRAID.warnCount"
SCRUB_COUNT_FILE="$CURRENT_DIR/snapRAID.scrubCount"
TMP_OUTPUT="/tmp/snapRAID.out"
SNAPRAID_LOG="/var/log/snapraid.log"
SECONDS=0 #Capture time
SNAPRAID_CONF="/etc/snapraid.conf"

# Expand PATH for smartctl
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Extract info from SnapRAID config
SNAPRAID_CONF_LINES=$(grep -E '^[^#;]' $SNAPRAID_CONF)

# Build an array of content files
IFS=$'\n' CONTENT_FILES=(
$(echo "$SNAPRAID_CONF_LINES" | grep snapraid.content | cut -d ' ' -f2)
)

# Build an array of parity all files...
IFS=$'\n' PARITY_FILES=(
  $(echo "$SNAPRAID_CONF_LINES" | grep -E '^([2-6z]-)*parity' | cut -d ' ' -f2- | tr ',' '\n')
)

# Read SnapRAID version
SNAPRAIDVERSION="$(snapraid -V | sed -e 's/snapraid v\(.*\)by.*/\1/')"

SYNC_MARKER="SYNC -"
SCRUB_MARKER="SCRUB -"

######################
#   MAIN SCRIPT      #
######################

function main(){
  # create tmp file for output
  true > "$TMP_OUTPUT"

  # Redirect all output to file and screen. Starts a tee process
  output_to_file_screen

  # timestamp the job?
  echo "SnapRAID Script Job started [$(date)]"
  echo "Running SnapRAID version $SNAPRAIDVERSION"
  echo "----------------------------------------"
  mklog "INFO: ----------------------------------------"
  mklog "INFO: SnapRAID Script Job started"
  mklog "INFO: Running SnapRAID version $SNAPRAIDVERSION"

  echo "## Pre-processing"

  # sanity check first to make sure we can access the content and parity files
  mklog "INFO: Checking SnapRAID disks"
  sanity_check

  echo "----------------------------------------"
  echo "## Processing"

  # Fix timestamps
  chk_zero

  # run the snapraid DIFF command
  echo "### SnapRAID DIFF [$(date)]"
  mklog "INFO: SnapRAID DIFF started"
  $SNAPRAID_BIN diff
  close_output_and_wait
  output_to_file_screen
  echo "DIFF finished [$(date)]"
  mklog "INFO: SnapRAID DIFF finished"
  JOBS_DONE="DIFF"

  # Get number of deleted, updated, and modified files...
  get_counts

  # sanity check to make sure that we were able to get our counts from the
  # output of the DIFF job
  if [[ -z $DEL_COUNT || -z $ADD_COUNT || -z $MOVE_COUNT || -z $COPY_COUNT || -z $UPDATE_COUNT ]]; then
    # failed to get one or more of the count values, lets report to user and
    # exit with error code
    echo "**ERROR** - Failed to get one or more count values. Unable to continue."
    mklog "WARN: Failed to get one or more count values. Unable to continue."
    echo "Exiting script. [$(date)]"
    if [[ $EMAIL_ADDRESS ]]; then
      SUBJECT="$EMAIL_SUBJECT_PREFIX WARNING - Unable to continue with SYNC/SCRUB job(s). Check DIFF job output."
      HC_OUTPUT="$SUBJECT"
      trim_log < "$TMP_OUTPUT" | send_mail
    fi
    exit 1;
  fi
  echo "**SUMMARY: Equal [$EQ_COUNT] - Added [$ADD_COUNT] - Deleted [$DEL_COUNT] - Moved [$MOVE_COUNT] - Copied [$COPY_COUNT] - Updated [$UPDATE_COUNT]**"
  mklog "INFO: SUMMARY: Equal [$EQ_COUNT] - Added [$ADD_COUNT] - Deleted [$DEL_COUNT] - Moved [$MOVE_COUNT] - Copied [$COPY_COUNT] - Updated [$UPDATE_COUNT]"

  # check if the conditions to run SYNC are met
  # CHK 1 - if files have changed
  if [[ $DEL_COUNT -gt 0 || $ADD_COUNT -gt 0 || $MOVE_COUNT -gt 0 || $COPY_COUNT -gt 0 || $UPDATE_COUNT -gt 0 ]]; then
    chk_del

    if [[ $CHK_FAIL -eq 0 ]]; then
      chk_updated
    fi

    if [[ $CHK_FAIL -eq 1 ]]; then
      chk_sync_warn
    fi
  else
    # NO, so let's skip SYNC
    echo "No change detected. Not running SYNC job. [$(date)]"
    mklog "INFO: No change detected. Not running SYNC job."
    DO_SYNC=0
  fi

  # Now run sync if conditions are met
  if [[ $DO_SYNC -eq 1 ]]; then
    echo "SYNC is authorized. [$(date)]"
    echo "### SnapRAID SYNC [$(date)]"
    mklog "INFO: SnapRAID SYNC Job started"
    if [[ $PREHASH -eq 1 ]]; then
      $SNAPRAID_BIN sync -h -q
    else
      $SNAPRAID_BIN sync -q
    fi
    close_output_and_wait
    output_to_file_screen
    echo "SYNC finished [$(date)]"
    mklog "INFO: SnapRAID SYNC Job finished"
    JOBS_DONE="$JOBS_DONE + SYNC"
    # insert SYNC marker to 'Everything OK' or 'Nothing to do' string to
    # differentiate it from SCRUB job later
    sed_me "
      s/^Everything OK/${SYNC_MARKER} Everything OK/g;
      s/^Nothing to do/${SYNC_MARKER} Nothing to do/g" "$TMP_OUTPUT"
    # Remove any warning flags if set previously. This is done in this step to
    # take care of scenarios when user has manually synced or restored deleted
    # files and we will have missed it in the checks above.
    if [[ -e $SYNC_WARN_FILE ]]; then
      rm "$SYNC_WARN_FILE"
    fi
  fi

  # Moving onto scrub now. Check if user has enabled scrub
  echo "### SnapRAID SCRUB [$(date)]"
  mklog "INFO: SnapRAID SCRUB Job started"
  if [[ $SCRUB_PERCENT -gt 0 ]]; then
    # YES, first let's check if delete threshold has been breached and we have
    # not forced a sync.
    if [[ $CHK_FAIL -eq 1 && $DO_SYNC -eq 0 ]]; then
      # YES, parity is out of sync so let's not run scrub job
      echo "Parity info is out of sync (deleted or changed files threshold has been breached)."
      echo "Not running SCRUB job. [$(date)]"
      mklog "INFO: Parity info is out of sync (deleted or changed files threshold has been breached). Not running SCRUB job."
    else
      # NO, delete threshold has not been breached OR we forced a sync, but we
      # have one last test - let's make sure if sync ran, it completed
      # successfully (by checking for the marker text in the output).
      if [[ $DO_SYNC -eq 1 ]] && ! grep -qw "$SYNC_MARKER" "$TMP_OUTPUT"; then
        # Sync ran but did not complete successfully so lets not run scrub to
        # be safe
        echo "**WARNING** - check output of SYNC job. Could not detect marker."
        echo "Not running SCRUB job. [$(date)]"
        mklog "WARN: Check output of SYNC job. Could not detect marker. Not running SCRUB job."
      else
        # Everything ok - ready to run the scrub job!
        # The fuction will check if scrub delayed run is enabled and run scrub
        # based on configured conditions
        chk_scrub_settings
      fi
    fi
  else
    echo "Scrub job is not enabled. "
    echo "Not running SCRUB job. [$(date)]"
    mklog "INFO: Scrub job is not enabled. Not running SCRUB job."
  fi

  echo "----------------------------------------"
  echo "## Post-processing"

  # Show SnapRAID SMART info if enabled
  if [[ $SMART_LOG -eq 1 ]]; then
    echo "### SnapRAID Smart"
    $SNAPRAID_BIN smart
    close_output_and_wait
    output_to_file_screen
  fi

  # Show SnapRAID Status information if enabled
  if [[ $SNAP_STATUS -eq 1 ]]; then
    echo "### SnapRAID Status"
    $SNAPRAID_BIN status
    close_output_and_wait
    output_to_file_screen
  fi

  # Spinning down disks (Method 1: snapraid - preferred)
  if [[ $SPINDOWN -eq 1 ]]; then
    echo "### SnapRAID Spindown"
    $SNAPRAID_BIN down
    close_output_and_wait
    output_to_file_screen
  fi

  # Spinning down disks (Method 2: hdparm - spins down all rotational devices)
  # if [ $SPINDOWN -eq 1 ]; then
  # for DRIVE in `lsblk -d -o name | tail -n +2`
  #   do
  #     if [[ `smartctl -a /dev/$DRIVE | grep 'Rotation Rate' | grep rpm` ]]; then
  #       hdparm -Y /dev/$DRIVE
  #     fi
  #   done
  # fi

  # Spinning down disks (Method 3: hd-idle - spins down all rotational devices)
  # if [ $SPINDOWN -eq 1 ]; then
  # for DRIVE in `lsblk -d -o name | tail -n +2`
  #   do
  #     if [[ `smartctl -a /dev/$DRIVE | grep 'Rotation Rate' | grep rpm` ]]; then
  #       echo "spinning down /dev/$DRIVE"
  #       hd-idle -t /dev/$DRIVE
  #     fi
  #   done
  # fi

  echo "All jobs ended. [$(date)]"
  mklog "INFO: Snapraid: all jobs ended."

  # all jobs done, let's send output to user if configured
  if [[ $EMAIL_ADDRESS ]]; then
    echo -e "Email address is set. Sending email report to **$EMAIL_ADDRESS** [$(date)]"
    # check if deleted count exceeded threshold
    prepare_mail

    ELAPSED="$((SECONDS / 3600))hrs $(((SECONDS / 60) % 60))min $((SECONDS % 60))sec"
    echo "----------------------------------------"
    echo "## Total time elapsed for SnapRAID: $ELAPSED"
    mklog "INFO: Total time elapsed for SnapRAID: $ELAPSED"

    # Add a topline to email body
    sed_me "1s:^:##$SUBJECT \n:" "${TMP_OUTPUT}"
    if [[ $VERBOSITY -eq 1 ]]; then
      send_mail < "$TMP_OUTPUT"
    else
      trim_log < "$TMP_OUTPUT" | send_mail
    fi
  fi

  # exit with success, letting the trap handle cleanup of file descriptors
  exit 0;
}

#######################
# FUNCTIONS & METHODS #
#######################

function sanity_check() {
  echo "Checking if all parity and content files are present."
  mklog "INFO: Checking if all parity and content files are present."
  for i in "${PARITY_FILES[@]}"; do
    if [[ ! -e $i ]]; then
    echo "[$(date)] ERROR - Parity file ($i) not found!"
    echo "ERROR - Parity file ($i) not found!" >> "$TMP_OUTPUT"
    echo "**ERROR**: Please check the status of your disks! The script exits here due to missing file or disk."
    mklog "WARN: Parity file ($i) not found!"
    mklog "WARN: Please check the status of your disks! The script exits here due to missing file or disk."
    # Add a topline to email body
    SUBJECT="$EMAIL_SUBJECT_PREFIX WARNING - Parity file ($i) not found!"
    HC_OUTPUT="$SUBJECT"
    trim_log < "$TMP_OUTPUT" | send_mail
    exit 1;
  fi
  done
  echo "All parity files found."
  printf '%s\n' "${PARITY_FILES[@]}"
  mklog "INFO: All parity files found."
  echo
  for i in "${CONTENT_FILES[@]}"; do
    if [[ ! -e $i ]]; then
      echo "[$(date)] ERROR - Content file ($i) not found!"
      echo "ERROR - Content file ($i) not found!" >> "$TMP_OUTPUT"
      echo "**ERROR**: Please check the status of your disks! The script exits here due to missing file or disk."
      mklog "WARN: Content file ($i) not found!"
      mklog "WARN: Please check the status of your disks! The script exits here due to missing file or disk."
      # Add a topline to email body
      SUBJECT="$EMAIL_SUBJECT_PREFIX WARNING - Content file ($i) not found!"
      HC_OUTPUT="$SUBJECT"
      trim_log < "$TMP_OUTPUT" | send_mail

    exit 1;
   fi
  done
  echo "All content files found."
  printf '%s\n' "${CONTENT_FILES[@]}"
  mklog "INFO: All content files found."
}

function get_counts() {
  EQ_COUNT=$(grep -w '^ \{1,\}[0-9]* equal' $TMP_OUTPUT | sed 's/^ *//g' | cut -d ' ' -f1)
  ADD_COUNT=$(grep -w '^ \{1,\}[0-9]* added' "$TMP_OUTPUT" | sed 's/^ *//g' | cut -d ' ' -f1)
  DEL_COUNT=$(grep -w '^ \{1,\}[0-9]* removed' "$TMP_OUTPUT" | sed 's/^ *//g' | cut -d ' ' -f1)
  UPDATE_COUNT=$(grep -w '^ \{1,\}[0-9]* updated' "$TMP_OUTPUT" | sed 's/^ *//g' | cut -d ' ' -f1)
  MOVE_COUNT=$(grep -w '^ \{1,\}[0-9]* moved' "$TMP_OUTPUT" | sed 's/^ *//g' | cut -d ' ' -f1)
  COPY_COUNT=$(grep -w '^ \{1,\}[0-9]* copied' "$TMP_OUTPUT" | sed 's/^ *//g' | cut -d ' ' -f1)
  # REST_COUNT=$(grep -w '^ \{1,\}[0-9]* restored' $TMP_OUTPUT | sed 's/^ *//g' | cut -d ' ' -f1)
}

function sed_me(){
  # Close the open output stream first, then perform sed and open a new tee
  # process and redirect output. We close stream because of the calls to new
  # wait function in between sed_me calls. If we do not do this we try to close
  # Processes which are not parents of the shell.
  exec >& "$OUT" 2>& "$ERROR"
  sed -i "$1" "$2"

  output_to_file_screen
}

function chk_del(){
  if [[ $DEL_COUNT -lt $DEL_THRESHOLD ]]; then
    if [[ $DEL_COUNT -eq 0 ]]; then
      echo "There are no deleted files, that's fine."
      DO_SYNC=1
    else
      echo "There are deleted files. The number of deleted files ($DEL_COUNT) is below the threshold of ($DEL_THRESHOLD)."
      DO_SYNC=1
    fi
  else
    echo "**WARNING** Deleted files ($DEL_COUNT) reached/exceeded threshold ($DEL_THRESHOLD)."
    mklog "WARN: Deleted files ($DEL_COUNT) reached/exceeded threshold ($DEL_THRESHOLD)."
    CHK_FAIL=1
  fi
}

function chk_updated(){
  if [[ $UPDATE_COUNT -lt $UP_THRESHOLD ]]; then
    if [[ $UPDATE_COUNT -eq 0 ]]; then
      echo "There are no updated files, that's fine."
      DO_SYNC=1
    else
      echo "There are updated files. The number of updated files ($UPDATE_COUNT) is below the threshold of ($UP_THRESHOLD)."
      DO_SYNC=1
    fi
  else
    echo "**WARNING** Updated files ($UPDATE_COUNT) reached/exceeded threshold ($UP_THRESHOLD)."
    mklog "WARN: Updated files ($UPDATE_COUNT) reached/exceeded threshold ($UP_THRESHOLD)."
    CHK_FAIL=1
  fi
}

function chk_sync_warn(){
  if [[ $SYNC_WARN_THRESHOLD -gt -1 ]]; then
    if [[ $SYNC_WARN_THRESHOLD -eq 0 ]]; then
      echo "Forced sync is enabled."
      mklog "INFO: Forced sync is enabled."
    else
      echo "Sync after threshold warning(s) is enabled."
      mklog "INFO: Sync after threshold warning(s) is enabled."
    fi

    local sync_warn_count
    sync_warn_count=$(sed '/^[0-9]*$/!d' "$SYNC_WARN_FILE" 2>/dev/null)
    # zero if file does not exist or did not contain a number
    : "${sync_warn_count:=0}"

    if [[ $sync_warn_count -ge $SYNC_WARN_THRESHOLD ]]; then
      # Force a sync. If the warn count is zero it means the sync was already
      # forced, do not output a dumb message and continue with the sync job.
      if [[ $sync_warn_count -eq 0 ]]; then
        DO_SYNC=1
      else
        # If there is at least one warn count, output a message and force a
        # sync job. Do not need to remove warning marker here as it is
        # automatically removed when the sync job is run by this script
        echo "Number of threshold warning(s) ($sync_warn_count) has reached/exceeded threshold ($SYNC_WARN_THRESHOLD). Forcing a SYNC job to run."
        mklog "INFO: Number of threshold warning(s) ($sync_warn_count) has reached/exceeded threshold ($SYNC_WARN_THRESHOLD). Forcing a SYNC job to run."
        DO_SYNC=1
      fi
    else
      # NO, so let's increment the warning count and skip the sync job
      ((sync_warn_count += 1))
      echo "$sync_warn_count" > "$SYNC_WARN_FILE"
      if [[ $sync_warn_count = $SYNC_WARN_THRESHOLD ]]; then
        echo  "This is the **last** warning left. **NOT** proceeding with SYNC job. [$(date)]"
        mklog "INFO: This is the **last** warning left. **NOT** proceeding with SYNC job. [$(date)]"
        DO_SYNC=0
      else
        echo "$((SYNC_WARN_THRESHOLD - sync_warn_count)) threshold warning(s) until the next forced sync. **NOT** proceeding with SYNC job. [$(date)]"
        mklog "INFO: $((SYNC_WARN_THRESHOLD - sync_warn_count)) threshold warning(s) until the next forced sync. **NOT** proceeding with SYNC job."
        DO_SYNC=0
      fi
    fi
  else
    # NO, so let's skip SYNC
    echo "Forced sync is not enabled. Check $TMP_OUTPUT for details. **NOT** proceeding with SYNC job. [$(date)]"
    mklog "INFO: Forced sync is not enabled. Check $TMP_OUTPUT for details. **NOT** proceeding with SYNC job."
    DO_SYNC=0
  fi
}

function chk_zero(){
  echo "### SnapRAID TOUCH [$(date)]"
  echo "Checking for zero sub-second files."
  TIMESTATUS=$($SNAPRAID_BIN status | grep 'You have [1-9][0-9]* files with zero sub-second timestamp\.' | sed 's/^You have/Found/g')
  if [[ -n $TIMESTATUS ]]; then
    echo "$TIMESTATUS"
    echo "Running TOUCH job to timestamp. [$(date)]"
    $SNAPRAID_BIN touch
    close_output_and_wait
    output_to_file_screen
  else
    echo "No zero sub-second timestamp files found."
  fi
  echo "TOUCH finished [$(date)]"
}

function chk_scrub_settings(){
    if [[ $SCRUB_DELAYED_RUN -gt 0 ]]; then
    echo "Delayed scrub is enabled."
    mklog "INFO: Delayed scrub is enabled.."
  fi

  local scrub_count
  scrub_count=$(sed '/^[0-9]*$/!d' "$SCRUB_COUNT_FILE" 2>/dev/null)
  # zero if file does not exist or did not contain a number
  : "${scrub_count:=0}"

    if [[ $scrub_count -ge $SCRUB_DELAYED_RUN ]]; then
    # Run a scrub job. if the warn count is zero it means the scrub was already
    # forced, do not output a dumb message and continue with the scrub job.
    if [[ $scrub_count -eq 0 ]]; then
      echo
      run_scrub
    else
      # if there is at least one warn count, output a message and force a scrub
      # job. Do not need to remove warning marker here as it is automatically
      # removed when the scrub job is run by this script
      echo "Number of delayed runs has reached/exceeded threshold ($SCRUB_DELAYED_RUN). A SCRUB job will run."
      mklog "INFO: Number of delayed runs has reached/exceeded threshold ($SCRUB_DELAYED_RUN). A SCRUB job will run."
      echo
      run_scrub
    fi
    else
    # NO, so let's increment the warning count and skip the scrub job
    ((scrub_count += 1))
    echo "$scrub_count" > "$SCRUB_COUNT_FILE"
    if [[ $scrub_count = $SCRUB_DELAYED_RUN ]]; then
      echo  "This is the **last** run left before running scrub job next time. [$(date)]"
      mklog "INFO: This is the **last** run left before running scrub job next time. [$(date)]"
    else
      echo "$((SCRUB_DELAYED_RUN - scrub_count)) runs until the next scrub. **NOT** proceeding with SCRUB job. [$(date)]"
      mklog "INFO: $((SCRUB_DELAYED_RUN - scrub_count)) runs until the next scrub. **NOT** proceeding with SCRUB job. [$(date)]"
    fi
    fi
}

function run_scrub(){
  $SNAPRAID_BIN scrub -p $SCRUB_PERCENT -o $SCRUB_AGE -q
  close_output_and_wait
  output_to_file_screen
  echo "SCRUB finished [$(date)]"
  mklog "INFO: SnapRAID SCRUB Job finished"
  JOBS_DONE="$JOBS_DONE + SCRUB"
  # insert SCRUB marker to 'Everything OK' or 'Nothing to do' string to
  # differentiate it from SYNC job above
  sed_me "
    s/^Everything OK/${SCRUB_MARKER} Everything OK/g;
    s/^Nothing to do/${SCRUB_MARKER} Nothing to do/g" "$TMP_OUTPUT"
  # Remove the warning flag if set previously. This is done now to
  # take care of scenarios when user has manually synced or restored
  # deleted files and we will have missed it in the checks above.
  if [[ -e $SCRUB_COUNT_FILE ]]; then
    rm "$SCRUB_COUNT_FILE"
  fi
}

function clean_desc(){
  [[ $- = *i* ]] && exec &>/dev/tty
 }

function final_cleanup(){
    clean_desc exit
}

function prepare_mail() {
  if [[ $CHK_FAIL -eq 1 ]]; then
    if [[ $DEL_COUNT -ge $DEL_THRESHOLD && $DO_SYNC -eq 0 ]]; then
      MSG="Deleted files ($DEL_COUNT) / ($DEL_THRESHOLD) violation"
    fi

    if [[ $DEL_COUNT -ge $DEL_THRESHOLD && $DO_SYNC -eq 1 ]]; then
      MSG="Forced sync with deleted files ($DEL_COUNT) / ($DEL_THRESHOLD) violation"
    fi

    if [[ $UPDATE_COUNT -ge $UP_THRESHOLD && $DO_SYNC -eq 0 ]]; then
      MSG="Changed files ($UPDATE_COUNT) / ($UP_THRESHOLD) violation"
    fi

    if [[ $UPDATE_COUNT -ge $UP_THRESHOLD && $DO_SYNC -eq 1 ]]; then
      MSG="Forced sync with changed files ($UPDATE_COUNT) / ($UP_THRESHOLD) violation"
    fi

    if [[ $DEL_COUNT -ge $DEL_THRESHOLD && $UPDATE_COUNT -ge $UP_THRESHOLD && $DO_SYNC -eq 0 ]]; then
      MSG="Multiple violations - Deleted files ($DEL_COUNT) / ($DEL_THRESHOLD) and changed files ($UPDATE_COUNT) / ($UP_THRESHOLD)"
    fi

    if [[ $DEL_COUNT -ge $DEL_THRESHOLD && $UPDATE_COUNT -ge $UP_THRESHOLD && $DO_SYNC -eq 1 ]]; then
      MSG="Sync forced with multiple violations - Deleted files ($DEL_COUNT) / ($DEL_THRESHOLD) and changed files ($UPDATE_COUNT) / ($UP_THRESHOLD)"
    fi
    SUBJECT="[WARNING] $MSG $EMAIL_SUBJECT_PREFIX"
    HC_OUTPUT="$SUBJECT"

  elif [[ ${JOBS_DONE##*"SYNC"*} ]] && ! grep -qw "$SYNC_MARKER" "$TMP_OUTPUT"; then
# Sync ran but did not complete successfully so lets warn the user
    SUBJECT="[WARNING] SYNC job ran but did not complete successfully $EMAIL_SUBJECT_PREFIX"
    HC_OUTPUT="$SUBJECT"

  elif [[ ${JOBS_DONE##*"SCRUB"*} ]] && ! grep -qw "$SCRUB_MARKER" "$TMP_OUTPUT"; then
    # Scrub ran but did not complete successfully so lets warn the user
    SUBJECT="[WARNING] SCRUB job ran but did not complete successfully $EMAIL_SUBJECT_PREFIX"
   HC_OUTPUT="$SUBJECT
SUMMARY: Equal [$EQ_COUNT] - Added [$ADD_COUNT] - Deleted [$DEL_COUNT] - Moved [$MOVE_COUNT] - Copied [$COPY_COUNT] - Updated [$UPDATE_COUNT]"

  else
    SUBJECT="[COMPLETED] $JOBS_DONE Jobs $EMAIL_SUBJECT_PREFIX"
    HC_OUTPUT="$SUBJECT
SUMMARY: Equal [$EQ_COUNT] - Added [$ADD_COUNT] - Deleted [$DEL_COUNT] - Moved [$MOVE_COUNT] - Copied [$COPY_COUNT] - Updated [$UPDATE_COUNT]"

  fi
}

# Trim the log file read from stdin.
function trim_log(){
  sed '
    /^Running TOUCH job to timestamp/,/^\TOUCH finished/{
      /^Running TOUCH job to timestamp/!{/^TOUCH finished/!d}
    };
    /^### SnapRAID DIFF/,/^\DIFF finished/{
      /^### SnapRAID DIFF/!{/^DIFF finished/!d}
    }'
  }

# Process and mail the email body read from stdin.
function send_mail(){
    local body; body=$(cat)
    # $MAIL_BIN -a 'Content-Type: text/html' -s "$SUBJECT" "$EMAIL_ADDRESS"
    # Allow the use of femtomail
    (echo "SUBJECT" "$body"; echo) | $MAIL_BIN "$EMAIL_ADDRESS"
}

# Due to how process substitution and newer bash versions work, this function
# stops the output stream which allows wait stops wait from hanging on the tee
# process. If we do not do this and use normal 'wait' the processes will wait
# forever as newer bash version will wait for the process substitution to
# finish. Probably not the best way of 'fixing' this issue. Someone with more
# knowledge can provide better insight.
function close_output_and_wait(){
  exec >& "$OUT" 2>& "$ERROR"
  CHILD_PID=$(pgrep -P $$)
  if [[ -n $CHILD_PID ]]; then
    wait "$CHILD_PID"
  fi
}

# Redirects output to file and screen. Open a new tee process.
function output_to_file_screen(){
  # redirect all output to screen and file
  exec {OUT}>&1 {ERROR}>&2
  # NOTE: Not preferred format but valid: exec &> >(tee -ia "${TMP_OUTPUT}" )
  exec > >(tee -a "${TMP_OUTPUT}") 2>&1
}

# Sends important messages to syslog
function mklog() {
  [[ "$*" =~ ^([A-Za-z]*):\ (.*) ]] &&
  {
    PRIORITY=${BASH_REMATCH[1]} # INFO, DEBUG, WARN
    LOGMESSAGE=${BASH_REMATCH[2]} # the Log-Message
  }
  echo "$(date '+[%Y-%m-%d %H:%M:%S]') $(basename "$0"): $PRIORITY: '$LOGMESSAGE'" >> "$SNAPRAID_LOG"
}

# Set TRAP
trap final_cleanup INT EXIT

main "$@"

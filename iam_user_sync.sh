#!/bin/bash -ex

# Ensure non-zero exit codes aren't swallowed by sed pipes
set -o pipefail

SSH_AUTHORIZED_KEYS_DIR=${SSH_AUTHORIZED_KEYS_DIR:-/etc/ssh/authorized_keys}
IAM_AUTHORIZED_GROUPS=${IAM_AUTHORIZED_GROUPS:-}
LOCAL_GROUPS=${LOCAL_GROUPS:-}
LOCAL_MARKER_GROUP=${LOCAL_MARKER_GROUP:-iam-user}

function get_local_users() {
  getent group ${LOCAL_MARKER_GROUP} \
  | cut -d : -f4- \
  | sed "s/,/ /g"
}

function get_remote_users() {
  for group in $(echo ${IAM_AUTHORIZED_GROUPS} | tr "," " "); do
    aws iam get-group \
      --group-name ${group} \
      --query "Users[].[UserName]" \
      --output text \
    | sed "s/\r//g"
  done
}

function create_update_local_user() {
  set +e
  if ! id ${1} >/dev/null 2>&1; then
    if command -v adduser >/dev/null 2>&1; then
      adduser ${1}
    else
      useradd -m ${1}
    fi
    chown -R ${1}:${1} /home/${1}
  fi
  usermod -G ${LOCAL_GROUPS},${LOCAL_MARKER_GROUP} ${1}
  set -e
}

function delete_local_user() {
  set +e
  usermod -L -s /sbin/nologin ${1}
  pkill -KILL -u ${1}
  userdel ${1}
  rm -f ${SSH_AUTHORIZED_KEYS_DIR}/${1}
  set -e
}

function gather_user_keys() {
  tmpfile=$(mktemp)
  key_ids=$(
    aws iam list-ssh-public-keys \
      --user-name ${1} \
      --query "SSHPublicKeys[?Status=='Active'].[SSHPublicKeyId]" \
      --output text \
    | sed "s/\r//g" || return 1 # Fail-fast if key listing fails
  )
  for key_id in ${key_ids}; do
    aws iam get-ssh-public-key \
      --user-name ${1} \
      --ssh-public-key-id ${key_id} \
      --encoding SSH \
      --query "SSHPublicKey.SSHPublicKeyBody" \
      --output text \
    >> ${tmpfile} || return 1 # Fail-fast if key gathering fails
  done
  chmod 644 ${tmpfile}
  mv ${tmpfile} ${SSH_AUTHORIZED_KEYS_DIR}/${1}
}

function sync_accounts() {
  if [ -z "${IAM_AUTHORIZED_GROUPS}" ]; then
    echo "Must specify one or more comma-separated IAM groups for IAM_AUTHORIZED_GROUPS" 1>&2
    exit 1
  fi

  local_users=$(get_local_users)
  remote_users=$(get_remote_users)
  intersection=$(echo ${local_users} ${remote_users} | tr " " "\n" | sort | uniq -D | uniq)
  removed_users=$(echo ${local_users} ${intersection} | tr " " "\n" | sort | uniq -u)

  for user in ${remote_users}; do
    create_update_local_user ${user}

    # We allow gather_user_keys to fail because we ensure it either a) gathers *all* keys for a
    # user, or b) makes no change to the user's local cached keys.
    set +e
    gather_user_keys ${user}
    set -e
  done

  for user in ${removed_users}; do
    delete_local_user ${user}
  done
}

sync_accounts

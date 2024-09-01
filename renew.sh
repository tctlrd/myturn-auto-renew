#!/bin/bash

# this script will renew all myturn.com checked out items to the max

# it requires that you have curl and jq installed on your machine
# set the login information variables below or the script will prompt you for them
# you can optionally have the script retain answers to the prompts which is slightly more secure

# syntax: ./renew.sh [-l|p|c|d|i]
# options:
# -f    fetch cookie
# -p    pull the latest loan list
# -c    read out the loan items
# -d    delete the files & settings created by this script
# -h    print help

# global variables

## login information to fetch cookie
USERNAME="" # your username
PASSWORD="" # your password

## file naming
PULL="raw-current-loans.json"
CURRENT="current-loans.json"
COOKIE="cookie"
ENV="env-renew"

## URLs
BASE=""
URL="https://login.myturn.com/library/"

# check if curl and jq are install
function cmdExists() { command -v "$1" >/dev/null 2>&1; }
FAIL=false
if ! cmdExists curl; then echo "curl is not installed. Please install it to proceed." && FAIL=true; fi
if ! cmdExists jq; then echo "jq is not installed. Please install it to proceed." && FAIL=true; fi
[[ $FAIL == true ]] && exit 1

# if the username and password variables are set in this file, remove them from the env file if it exists
[ -n "$USERNAME" ] && [ -f $ENV ] && sed -i '/USERNAME/d' $ENV
[ -n "$PASSWORD" ] && [ -f $ENV ] && sed -i '/WORD/d' $ENV

# if the env file exists source it for saved variables
[ -f $ENV ] && source $ENV

# function to test if valid cookie file exists for pull; else fetch cookie
function Cookie() {
  if [ -f $COOKIE ] && [ -n "$BASE" ] && find $COOKIE -mmin -10 | grep -q .; then
    echo "recent cookie found and being tested"
    CCODE=$( curl ${BASE}myAccount/editMembership  -b $COOKIE -s -w "%{http_code}" -o /dev/null)
    [ "$CCODE" -ne "200" ] && echo "cookie was tested and found to be useless; we will attempt to replace her" && fetchCookie
  else
    fetchCookie
  fi
}

# function to fetch a cookie from the server
function fetchCookie() {
  if [ -z "$USERNAME" ]; then
    read -p "username: " USERNAME
    MEM_U=true
    [ -f $ENV ] && sed -i -e '/USERNAME/d' -e '/PASSWORD/d' $ENV
  fi
  ZAP=$(echo -n "$USERNAME" | openssl dgst -sha256 | cut -d ' ' -f 2)
  [ -n "$PASSWORD" ] && PASSWORD=$(echo -n "$PASSWORD"  | openssl enc -aes-256-cbc -salt -pass pass:"$ZAP" -pbkdf2 -base64)
  [ -n "$WORD" ] && PASSWORD="$WORD"
  if [ -z "$PASSWORD" ]; then
    read -s -p "password: " PASSWORD && echo
    PASSWORD=$(echo -n "$PASSWORD" | openssl enc -aes-256-cbc -salt -pass pass:"$ZAP" -pbkdf2 -base64)
    read -p "Do you want to save these credentials? (y/n): " MEM_L
  fi
  echo "attempting to fetch cookie from myturn.com as user \"${USERNAME}\""
  find $COOKIE -mmin -10 | grep -q . && mv $COOKIE ${COOKIE}_bkp
  SESH=$(curl ${URL}j_spring_security_check -d "j_username=${USERNAME}&j_password=$(echo "$PASSWORD" | openssl enc -d -aes-256-cbc -salt -pass pass:"$ZAP" -pbkdf2 -base64)" -c $COOKIE -s -w "%header{location}")
  if [[ "$SESH" == *"authfail"* ]]; then
    [ -f $ENV ] && source $ENV
    [ -f $ENV ] && rm -v $ENV
    echo "cookie fetch has failed; check your username and password"
    [ -f ${COOKIE}_bkp ] && mv ${COOKIE}_bkp $COOKIE
    [ -n "$BASE" ] && echo "export BASE=\""$BASE"\"" >> $ENV
    exit 1
  elif [[ "$SESH" == *"library"* ]]; then
    echo "cookie fetch success!"
    if [[ $MEM_L == "y" ]]; then
      [ -f $ENV ] && sed -i -e '/USERNAME/d' -e '/PASSWORD/d' $ENV
      [[ $MEM_U == true ]] && echo "export USERNAME=\"$USERNAME\"" >> $ENV
      echo "export WORD=\""$PASSWORD"\"" >> $ENV
    fi
    [ -f ${COOKIE}_bkp ] && rm -f ${COOKIE}_bkp
    [ -f $ENV ] && source $ENV
    [ -n "$BASE" ] && sed -i '/BASE/d' $ENV
    BASE=$(curl ${URL}login/redirectToOrg -b $COOKIE -s -w "%header{location}")
    echo "export BASE=\""$BASE"\"" >> $ENV
    sed -i "s/_login/_$(echo "$BASE" | sed -E 's|.*//([^\.]+)\.my.*|\1|')/g" cookie
    [ -z "$MEMBERSHIP_ID" ] && getId
    return 0
  else
    [ -f $ENV ] && rm -v $ENV
    echo "unknown login error at location \""$SESH"\"; check domain"
    exit 1
  fi
}

# function to retrieve the membership type id from the server and save it to the env for renewal requests
function getId() {
  [ -f $ENV ] && sed -i '/MEMBERSHIP_ID/d' $ENV
  MEMBERSHIP_ID=$(curl -s ${BASE}myAccount/editMembership -b $COOKIE | grep -oP 'checkAgreementSignatures\(\K\d+')
  echo "export MEMBERSHIP_ID=\"$MEMBERSHIP_ID\"">> $ENV
  echo "your membership type id has been retrieved as \"$MEMBERSHIP_ID\""
}

# function to save to download the json of the users loans and save it as a file containing only the currently checked out items
function Pull() {
  LSTMP=$(mktemp)
  echo "attempting to pull the loans list from the server"
  CODE=$(curl ${BASE}myLoans/listLoansJSON -b $COOKIE -w "%{http_code}" -o $LSTMP)
  if [ $CODE -ne 200 ]; then
    [ -f $ENV ] && rm -v $ENV
    echo "the pull failed with http response code: \""$CODE"\""
    echo "make sure you are logged in with option -l"
    exit 1
  fi
  jq '[.data[]
    | select(.isCheckedOut == true)
    | walk(if . == null then "" else . end)]' $LSTMP > $PULL
  echo "loan list pull success!"
}

# function to display the relevant info from the loan list file and save it as a new file
function Current() {
  [ ! -f $PULL ] && echo "first pull the loan list with option -p" && exit 1
  echo "displaying relevant info from $PULL and saving it as $CURRENT"; echo
  jq '[.[]
      | {item: (.item.displayName | gsub("\\\"";"in")), id: .item.internalId, renewable: .renewable, remaining: .renewalsLeft, max: .maxRenewalDate, out: .checkedOutTimestamp, due: .dueDate}
      | (.out, .due, .max) |= sub("T.*";"")
      | with_entries(select(.value != "")) ]
      | sort_by(.renewable == true | if . then 1 else 0 end)' $PULL > $CURRENT
  jq '.' $CURRENT
}

# function called by the renew function to gather the data from the loan list file and prerform the renewal requests to the server
function renewLoop() {
  jq -c '.[]
    | select(.renewable == true)
    | {item: (.item.displayName | gsub("\\\"";"in")), loans: .id, itemId: .item.id, dueDate_date: (.maxRenewalDate | sub("T.*";"")), max: (.maxRenewalDate | sub("T.*";""))}
    | .dueDate_date |= (split("-") | "\(.|.[1] | tonumber)/\(.|.[2] | tonumber)/\(.|.[0])") | join("|")' $PULL | \
  while IFS='|' read -r ITEM LOANS ITEM_ID DUE_DATE_DATE MAX; do
    d=--data-urlencode
    echo "renewing $ITEM until $MAX"
    curl ${BASE}myLoans/renew -b $COOKIE \
      $d "loans=$LOANS" \
      $d "membershipId=$MEMBERSHIP_ID" \
      $d "itemId=$ITEM_ID" \
      $d "dueDate=struct" \
      $d "dueDate_date=$DUE_DATE_DATE"
  done
}

# function to login, pull the loan list, and loop through all renewable loan items to their maximum renewal date
# and then loop through re-pulling the loan list until all items are renewed as many times as allowed
function Renew() {
  Cookie
  Pull
  while $(jq 'any(.renewable == true)' $PULL); do
    [ -z "$MEMBERSHIP_ID" ] && getId
    echo "renewable item(s) found in $PULL"
    renewLoop
    Pull
  done
  Current
  echo;echo "there are zero renewable items; try again tomorrow";echo
}

function Delete() {
  DELETE=("$PULL" "$CURRENT" "$COOKIE" "${COOKIE}_bkp" "$ENV")
  for FILE in "${DELETE[@]}"; do
    [ -f "$FILE" ] && rm -v "$FILE"
  done
  echo;echo "all files created by this script have been removed";echo
}

# function to display basic usage of this script
function Help() {
   echo
   echo "this script will renew all myturn.com checked out items to the max"
   echo "it requires that you have curl and jq installed on your machine"
   echo
   echo "syntax: ./renew.sh [-l|p|c|d|h]"
   echo "options:"
   echo "-f   fetch cookie"
   echo "-p   pull the latest loan list"
   echo "-c   read out the loan items"
   echo "-d   delete all files created by this script"
   echo "-h   print this help"
   echo
}

# options to control this script
while getopts ":fpcdh" opt; do
  case $opt in
  f) fetchCookie; exit;;
  p) Pull; exit;;
  c) Current; exit;;
  d) Delete; exit;;
  h) Help; exit;;
  \?) echo "Invalid option: -${OPTARG}."; exit 1;;
  esac
done

# if no options are called default to running the renew function
Renew
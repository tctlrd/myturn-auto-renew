#!/bin/bash

# this script will renew all myturn.com checked out items to the max

# it requires that you have curl and jq installed on your machine
# set the login information variables below or the script will prompt you for them
# you can optionally have the script retain answers to the prompts which is slightly more secure

# syntax: ./renew.sh [-l|p|c|d|i]
# options:
# -l    login
# -p    pull the latest loan list
# -c    read out the loan items
# -d    delete the files & settings created by this script
# -h    print help

# login information
DOMAIN="" # xyz.myturn.com
USERNAME="" # your username
PASSWORD="" # your password

# output file naming
PULL=raw-current-loans.json
CURRENT=current-loans.json

# if the username and password variables are set in this file, remove them from the env file if it exists
[ -n "$USERNAME" ] && [ -f env-renew.sh ] && sed -i '/USERNAME/d' env-renew.sh
[ -n "$PASSWORD" ] && [ -f env-renew.sh ] && sed -i '/WORD/d' env-renew.sh
 
# if the domain variable is set in this file remove it from the env file
[ -n "${DOMAIN}" ] && [ -f env-renew.sh ] && sed -i '/DOMAIN/d' env-renew.sh

# if the env file exists source it for saved variables
[ -f env-renew.sh ] && source env-renew.sh

# if the domain variable has been set or saved in the env, set it to the base url otherwise only decalare the empty base variable
if [ -n "${DOMAIN}" ]; then
  BASE="https://${DOMAIN}/library/"
else BASE=""; fi

# function to ask the user to set the domain variable and optionally remember it
setDomain(){
  if [ -z "$DOMAIN" ]; then
    echo "kindly enter the domain of your myTurn site"
    echo "(ie. xyz.myturn.com)"
    read -p "domain: " DOMAIN
    BASE="https://${DOMAIN}/library/"
    read -p "Do you want to save this domain? (y/n): " MEM_D
    [ $MEM_D == "y" ] && echo "export DOMAIN=\"$DOMAIN\"" >> env-renew.sh
  fi
  DOMAIN_T=$(printf "%s" "$DOMAIN" | openssl dgst -sha256 | cut -d ' ' -f 2)
  [ -n "$PASSWORD" ] && PASSWORD=$(echo -n "$PASSWORD" | openssl enc -aes-256-cbc -salt -pass pass:"$DOMAIN_T" -pbkdf2 -base64)
}

# function to login to the server and save the session in a cookie file
Login() {
  setDomain
  if [ -z "$USERNAME" ]; then
    read -p "username: " USERNAME
    MEM_U=true
    [ -f env-renew.sh ] && sed -i -e '/USERNAME/d' -e '/PASSWORD/d' env-renew.sh
  fi
  [ -n "$WORD" ] && PASSWORD="$WORD"
  if [ -z "$PASSWORD" ]; then
  read -s -p "password: " PASSWORD
  PASSWORD=$(echo -n "$PASSWORD" | openssl enc -aes-256-cbc -salt -pass pass:"$DOMAIN_T" -pbkdf2 -base64)
  echo
  read -p "Do you want to save these credentials? (y/n): " MEM_L
  fi
  echo "attempting to log into $DOMAIN as user \"${USERNAME}\""
  [ -f cookie ] && mv cookie cookie_bkp
  SESH=$(curl ${BASE}j_spring_security_check -d "j_username=${USERNAME}&j_password=$(echo "$PASSWORD" | openssl enc -d -aes-256-cbc -salt -pass pass:"$DOMAIN_T" -pbkdf2 -base64)" -c cookie -s -w "%header{location}")
  if [[ "$SESH" == *"authfail"* ]]; then
    [ -f env-renew.sh ] && sed -i -e '/USERNAME/d' -e '/PASSWORD/d' env-renew.sh
    echo "login has failed; check your username and password"
    [ -f cookie_bkp ] && mv cookie_bkp cookie
    exit 1
  elif [[ "$SESH" == *"library"* ]]; then
    echo "login success!"
    if [[ $MEM_L == "y" ]]; then
      [ -f env-renew.sh ] && sed -i -e '/USERNAME/d' -e '/PASSWORD/d' env-renew.sh
      [[ $MEM_U == true ]] && echo "export USERNAME=\"$USERNAME\"" >> env-renew.sh
      echo "export WORD=\""$PASSWORD"\"" >> env-renew.sh
    fi
    [ -f cookie_bkp ] && rm -f cookie_bkp
    [ -f env-renew.sh ] && source env-renew.sh
    [ -z "$MEMBERSHIP_ID" ] && getId
    return 0
  else echo "unknown login error; check url"; exit 1
  fi
}

# function to retrieve the membership type id from the server and save it to the env for renewal requests
getId() {
  [ -f env-renew.sh ] && sed -i '/MEMBERSHIP_ID/d' env-renew.sh
  MEMBERSHIP_ID=$(curl -s ${BASE}myAccount/editMembership -b cookie | grep -oP 'checkAgreementSignatures\(\K\d+')
  echo "export MEMBERSHIP_ID=\"$MEMBERSHIP_ID\"">> env-renew.sh
  echo "your membership type id has been retrieved as \"$MEMBERSHIP_ID\""
}

# function to save to download the json of the users loans and save it as a file containing only the currently checked out items
Pull() {
  setDomain
  LSTMP=$(mktemp)
  echo "attempting to pull the loans list from the server"
  CODE=$(curl ${BASE}myLoans/listLoansJSON -b cookie -w "%{http_code}" -o $LSTMP)
  [ $CODE -ne 200 ] && echo "the pull failed with http response code: \"$CODE\"; make sure you are logged in with option -l" && exit 1
  jq '[.data[]
    | select(.isCheckedOut == true)
    | walk(if . == null then "" else . end)]' $LSTMP > $PULL
  echo "loan list pull success!"
}

# function to display the relevant info from the loan list file and save it as a new file
Current() {
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
renewLoop() {
  jq -c '.[]
    | select(.renewable == true)
    | {item: (.item.displayName | gsub("\\\"";"in")), loans: .id, itemId: .item.id, dueDate_date: (.maxRenewalDate | sub("T.*";"")), max: (.maxRenewalDate | sub("T.*";""))}
    | .dueDate_date |= (split("-") | "\(.|.[1] | tonumber)/\(.|.[2] | tonumber)/\(.|.[0])") | join("|")' $PULL | \
  while IFS='|' read -r ITEM LOANS ITEM_ID DUE_DATE_DATE MAX; do
    d=--data-urlencode
    echo "renewing $ITEM until $MAX"
    curl ${BASE}myLoans/renew -b cookie \
      $d "loans=$LOANS" \
      $d "membershipId=$MEMBERSHIP_ID" \
      $d "itemId=$ITEM_ID" \
      $d "dueDate=struct" \
      $d "dueDate_date=$DUE_DATE_DATE"
  done
}

# function to login, pull the loan list, and loop through all renewable loan items to their maximum renewal date
# and then loop through re-pulling the loan list until all items are renewed as many times as allowed
Renew() {
  Login
  Pull
  while $(jq 'any(.renewable == true)' $PULL); do
    echo "renewable item(s) found in $PULL"
    renewLoop
    Pull
  done
  Current
  echo;echo "there are zero renewable items; try again tomorrow";echo
}

Delete() {
  DELETE=("$PULL" "$CURRENT" "cookie" "cookie_bkp" "env-renew.sh")
  for FILE in "${DELETE[@]}"; do
    [ -f "$FILE" ] && rm -v "$FILE"
  done
  echo;echo "all files created by this script have been removed";echo
}

# function to display basic usage of this script
Help() {
   echo
   echo "this script will renew all myturn.com checked out items to the max"
   echo
   echo "syntax: ./renew.sh [-l|p|c|d|h]"
   echo "options:"
   echo "-l   login"
   echo "-p   pull the latest loan list"
   echo "-c   read out the loan items"
   echo "-d   delete all files created by this script"
   echo "-h   print this help"
   echo
}

# options to control this script
while getopts ":lpcdh" opt; do
  case $opt in
  l) Login; exit;;
  p) Pull; exit;;
  c) Current; exit;;
  d) Delete; exit;;
  h) Help; exit;;
  \?) echo "Invalid option: -${OPTARG}."; exit 1;;
  esac
done
# if no options are called default to running the renew function
Renew

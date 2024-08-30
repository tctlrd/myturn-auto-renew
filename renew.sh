#!/bin/bash

# this script will renew all myturn.com checked out items to the max

# it requires that you have curl and jq installed on your machine
# set the login information variables below

# syntax: ./renew.sh [-l|p|c|d|i]
# options:
# -l    login
# -p    pull the latest loan list
# -c    read out the loan items
# -d    delete all files created by this script
# -h    print help

# login information
domain="yourSUBDOMAIN.myturn.com"
username="yourUSERNAME"
password="yourPASSWORD"

# output file naming
pull=raw-current-loans.json
current=current-loans.json

# base url for script
base="https://${domain}/library/"

Login() {
  echo "attempting to log into $domain as user \"${username}\""
  [ -f cookie ] && mv cookie cookie_bkp
  ses=$(curl ${base}j_spring_security_check -d "j_username=${username}&j_password=${password}" -c cookie -s -w "%header{location}")
  if [[ "$ses" == *"library"* ]]; then
    echo "login success!"
    [ -f cookie_bkp ] && rm -f cookie_bkp
    [ ! -f id ] && Id
    return 0
  elif [[ "$ses" == *"authfail"* ]]; then
    echo "login has failed; check your username and password"
    [ -f cookie_bkp ] && mv cookie_bkp cookie
    exit 1
  else echo "unknown login error; check url"; exit 1
  fi
}

Id() {
  curl -s ${base}myAccount/editMembership -b cookie | grep -oP 'checkAgreementSignatures\(\K\d+' > id
  echo "your membership type id has been retrieved as \"$(< id)\""
}

Pull() {
  lstmp=$(mktemp)
  echo "attempting to pull the loans list from the server"
  code=$(curl ${base}myLoans/listLoansJSON -b cookie -w "%{http_code}" -o $lstmp)
  [ $code -ne 200 ] && echo "the pull failed with http response code: \"$code\"; make sure you are logged in with option -l" && exit 1
  jq '[.data[]
    | select(.isCheckedOut == true)
    | walk(if . == null then "" else . end)]' $lstmp > $pull
  echo "loan list pull success!"
}

Current() {
  [ ! -f $pull ] && echo "first pull the loan list with option -p" && exit 1
  echo "displaying relevant info from $pull and saving it as $current"; echo
  jq '[.[]
      | {item: (.item.displayName | gsub("\\\"";"")), id: .item.internalId, renewable: .renewable, remaining: .renewalsLeft, max: .maxRenewalDate, out: .checkedOutTimestamp, due: .dueDate}
      | (.out, .due, .max) |= sub("T.*";"")
      | with_entries(select(.value != "")) ]
      | sort_by(.renewable == true | if . then 1 else 0 end)' $pull > $current
  jq '.' $current
}

RenewLoop() {
  membershipId=$(< id)
  jq -c '.[]
    | select(.renewable == true)
    | {item: (.item.displayName | gsub("\\\"";"")), loans: .id, itemId: .item.id, dueDate_date: (.maxRenewalDate | sub("T.*";"")), max: (.maxRenewalDate | sub("T.*";""))}
    | .dueDate_date |= (split("-") | "\(.|.[1] | tonumber)/\(.|.[2] | tonumber)/\(.|.[0])") | join("|")' $pull | \
  while IFS='|' read -r item loans itemId dueDate_date max; do
    d=--data-urlencode
    echo "renewing $item until $max"
    curl ${base}myLoans/renew -b cookie \
      $d "loans=$loans" \
      $d "membershipId=$membershipId" \
      $d "itemId=$itemId" \
      $d "dueDate=struct" \
      $d "dueDate_date=$dueDate_date"
  done
}

Renew() {
  Login
  Pull
  while $(jq 'any(.renewable == true)' $pull); do
    echo "renewable item(s) found in $pull"
    RenewLoop
    Pull
  done
  Current
  echo;echo "there are zero renewable items; try again tomorrow";echo
}

Help()
{
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

while getopts ":lpcdh" opt; do
  case $opt in
  l) Login; exit;;
  p) Pull; exit;;
  c) Current; exit;;
  d) rm -v *loans.json cookie* id; echo "all files created by this script have been removed"; exit;;
  h) Help; exit;;
  \?) echo "Invalid option: -${OPTARG}."; exit 1;;
  esac
done

Renew

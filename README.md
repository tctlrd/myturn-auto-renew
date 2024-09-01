# myturn auto renew

I wrote this script because my local tool library uses the [myturn.com](https://myturn.com) web app to manage its services.  
Renewing items on the web app is a very slow and cumbersom process due to its poor design.  

```
this script will renew all myturn.com checked out items to the max

it requires that you have curl and jq installed on your machine
set the login information variables or the script will prompt you for them
you can optionally have the script retain answers to the prompts which is slightly more secure

syntax: ./renew.sh [-f|p|c|d|i]
options:
-f    fetch cookie
-p    pull the latest loan list
-c    read out the loan items
-d    delete the files & settings created by this script
-h    print help

```

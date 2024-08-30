# myturn-auto-renew

I wrote this script because my local tool library uses the [myturn.com](https://myturn.com) web app to manage its services.  
Renewing items on the web app is a very slow and cumbersom process due to its poor design.  

```
this script will renew all myturn.com checked out items to the max  

it requires that you have curl and jq installed on your machine  
set the login information variables and let her rip  
the script will auto renew all items as many times as possible to their maximum renew date  
there are also options if you want to access your loan list data without renewing  

syntax: ./renew.sh [-l|p|c|d|i]  
options:  
-l    login  
-p    pull the latest loan list  
-c    read out the loan items  
-d    delete all files created by this script  
-h    print help
```

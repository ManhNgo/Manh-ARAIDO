#!/bin/sh
### release
# v.1.0 20230920 by ManhNT

### configuration
totalbps=16000000

pausePercent=$(echo "95 * $totalbps / 100" | bc)
resumePercent=$(echo "90 * $totalbps /100" | bc)

lbadmin=/castis/bin/tools/LBAdmin_64
hlsConfigPath=/castis/bin/CiLLBServer/CiLLBServer.cfg
dashConfigPath=/castis/bin/slb/slb.yml

logPath=/castis/log/monitor_log/session_controller_log/`date +%F`
if ! [ -d $logPath ]
then
	mkdir -p $logPath
fi

cnt=0
for ip in `cat $hlsConfigPath | egrep Server[0-9]+_Address | cut -d'=' -f2`
do
	ipList[$cnt]="$ip"
	((cnt++))
done
# Calculate the total bandwidth usage for HLS and DASH
totalHLSUsage=0
totalDASHUsage=0

### HLS usage
$lbadmin 127.0.0.1 888 all status | grep ^[0-9] > .hlstmp
while read line
do
	vodNum=`echo $line | cut -d'(' -f1`
	vodIP=`echo $line | cut -d'(' -f2 | cut -d')' -f1`
	curbps=`echo $line | awk '{print $3}' | cut -d'[' -f1 | cut -d'/' -f1`
	status=`echo $line | awk '{print $2}'`
	if [ `echo $curbps | grep -i m | wc -l` -eq 1 ]
	then
		curbps=`expr $curbps \* 1000`
	else
		curbps=`expr $curbps \* 1000000`
	fi
	usgae=$(echo "scale=2; ($curbps / $totalbps) * 100" | bc)
    totalHLSUsage=$((totalHLSUsage + usgae))
    echo "`date +%F' '+%T`,INFO,vodNum[${vodNum}]vodIP[${vodIP}]curbps[${curbps}]usgae[${usgae}%]status[${status}]" >> ${logPath}/monitor.txt
done < .hlstmp

### DASH use
slb=`cat $dashConfigPath | grep api-listen-addresses -A 1 | sed -n 2p | cut -d':' -f2,3`
curl "${slb}/api/nodes" | python -m json.tool > .dashtmp 

for server in `cat $dashConfigPath| grep hash-key: | awk '{print $3}'`
do
   vodIP=`cat $dashConfigPath | grep $server -A 10 | grep websocket-url | cut -d'/' -f3 | cut -d':' -f1`
   curbps=`cat .dashtmp | grep $server -A 5 | grep \"bps\" | awk '{print $2}'| cut -d',' -f1`
   status=`cat .dashtmp | grep $server -A 5 | grep paused | awk '{print $2}' | cut -d',' -f1`
   if [ "$status" == "false" ]
   then
      status="Running"
   else
      status="Paused"
   fi
   usgae=$(echo "scale=2; ($curbps / $totalbps) * 100" | bc)
   totalDASHUsage=$((totalDASHUsage + usgae))
   echo "`date +%F' '+%T`,INFO,vodIP[${vodIP}]curbps[${curbps}]usgae[${usgae}%]status[${status}]" >> ${logPath}/monitor.txt
done

# Calculate the total usage percentage for HLS and DASH
totalUsage=$((totalHLSUsage + totalDASHUsage))

# Check if the total usage exceeds 95%
if [ $totalUsage -ge $pausePercent ] && [ "$status" == "Running" ]
then
    # Perform actions to pause both HLS and DASH

    #pause both services
    echo "`date +%F' '+%T`,INFO,Total bandwidth usage exceeds 95%. Pausing HLS and DASH." >> ${logPath}/monitor.txt

    #Pause HLS
    $lbadmin 127.0.0.1 888 VOD${vodNum} pause
	echo "`date +%F' '+%T`,WARN,$lbadmin 127.0.0.1 888 VOD${vodNum} pause" >> ${logPath}/monitor.txt

    #Pause DASH
    curl --header "Content-Type: application/json" --request PUT --data '{"pause":true}' http://${slb}/api/nodes/${server}
	echo "`date +%F' '+%T`,WARN,curl --header "Content-Type: application/json" --request PUT --data '{"pause":true}' http://${slb}/api/nodes/${server}" >> ${logPath}/monitor.txt
fi
# Check if the total usage < 90%
if [ "$status" == "Paused" ] && [ $totalUsage -le $resumePercent ]
then 
    # Perform actions to running both HLS and DASH again

    echo "`date +%F' '+%T`,INFO,Total bandwidth usage less than 90%. Running HLS and DASH." >> ${logPath}/monitor.txt

    #Running HLS
    $lbadmin 127.0.0.1 888 VOD${vodNum} run
	echo "`date +%F' '+%T`,WARN,$lbadmin 127.0.0.1 888 VOD${vodNum} run" >> ${logPath}/monitor.txt

    #Running DASH
    curl --header "Content-Type: application/json" --request PUT --data '{"pause":false}' http://${slb}/api/nodes/${server}
	echo "`date +%F' '+%T`,WARN,curl --header "Content-Type: application/json" --request PUT --data '{"pause":false}' http://${slb}/api/nodes/${server}" >> ${logPath}/monitor.txt
fi

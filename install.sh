#!/bin/bash

#fill out these fields so that there would be no interruption during installtion
#ie. domain=www.example.com
domain=
#default password, ie. default_passwd=admin
default_passwd=
#url to fake website template, git repository url required
web_template=https://github.com:peterlee1213/a_third_party_static_web_template.git

apps_to_be_installed="trojan apache2 tar git certbot"  #apps to be installed in【Install trojan】
apps_to_be_removed="trojan apache2 git certbot" #apps to be removed in【Delete trojan】
trojan_keys_dir="/etc/trojan/trojan-keys/"	#location where public and private key lay
trojan_config_dir="/etc/trojan" # do not change this config
certbot_certs_dir="/etc/letsencrypt/live"  #location where public and private key is generated



echo_red(){
	echo -e "\033[31m[!] $1\033[0m"
}
echo_green(){
	echo -e "\033[32m[+] $1\033[0m"
}
echo_yellow(){
	echo -e "\033[33m[-] $1\033[0m"
}
echo_head_warning(){
	echo_red "Avoid using this script in production environment."
}


check_if_system_deb(){
	if uname -a | egrep --ignore-case "(ubuntu|debian)" &> /dev/null; then
		echo_green "distribution check pass"
	else
		echo_red "please run this script on ubuntu or debian"
		exit 1
	fi
}

check_if_run_as_root(){
	user_id=$(id -u)
	if [ $user_id -ne 0 ]; then
		echo_red "please run this script with root"
		exit 1
	fi
}

check_if_80_443_occupied(){
	if netstat &> /dev/null; then
		local command="netstat"
	else
		local command="ss"
	fi

	if $command -tnl | awk '{print $4}' | egrep "[[:digit:]]+$" --only-matching | egrep "^(80|443)$" &> /dev/null; then
		echo_red "80 or 443 port being occupied, exiting..."
		exit 1
	else
		echo_green "80 and 443 port available"
		return 0
	fi
}

check_assign_var_domain(){
	while true; do
		if [ -z $domain ]; then
			read -p "Input the domain(pointing to the Ipv4 addr of current VPS):" domain
		fi
		if check_if_domain_pointed_to_localhost $domain; then
			echo_green "Domain check pass"
			break;
		else
			echo_red "Illegal domain: [$domain], maybe DNS resolution is not pointing to current VPS, or DNS resolution hasn't came to effect"
			domain=
		fi
	done
}

check_if_domain_pointed_to_localhost(){
	apt-get update
	apt-get install host curl -y
	local pub_ip=$(curl ifconfig.me)
	if host $1 | fgrep $pub_ip &> /dev/null; then
		return 0
	else
		return 1
	fi
}


check_if_default_passwd_available(){
	while true; do
		if [ -z $default_passwd ]; then
			read -p "Please input password(only consisit of Letters and Numbers)" default_passwd
		fi

		if echo $default_passwd | egrep "^[[:alnum:]]+$" &> /dev/null; then	
			echo_green "Password Set"
			break;
		else
			echo_red "Illegal password"
			default_passwd=
		fi
	done
}

check_if_alnum(){
	if echo $1 | egrep "^[[:alnum:]]+$" &> /dev/null; then
		return 0
	else
		echo $2
		return 1
	fi
}

install_trojan(){
	install_check
	install_essential_apps
	install_fake_web_html
	install_cert
	install_modify_trojan_config
	install_bbr
	install_end_output
}

delete_trojan(){
	delete_check
	delete_installed_apps
	delete_stop_service
}

install_check(){
	check_if_system_deb
	check_if_80_443_occupied
	check_if_run_as_root
	check_assign_var_domain
	check_if_default_passwd_available
}

install_essential_apps(){
	apt-get update
	apt-get install $apps_to_be_installed -y
}

install_fake_web_html(){
	rm -rf /var/www/html/*
	git clone $web_template "/var/www/html"
	systemctl start apache2.service
	systemctl enable apache2.service
}

install_cert(){
	[ -e $trojan_keys_dir ] || mkdir $trojan_keys_dir
	systemctl stop apache2.service
	certbot certonly -d $domain --agree-tos --no-eff-email --standalone --register-unsafely-without-email --force-renewal 
	systemctl start apache2.service
	cp $certbot_certs_dir/${domain}*/*.pem $trojan_keys_dir
	chmod 755 $trojan_keys_dir
	chmod 444 $trojan_keys_dir/*.pem
}

install_modify_trojan_config(){
	[ -e $trojan_config_dir/config.json ] && mv $trojan_config_dir/config.json{,.backup}
cat << EOF > $trojan_config_dir/config.json
{
    "run_type": "server",
    "local_addr": "0.0.0.0",
    "local_port": 443,
    "remote_addr": "127.0.0.1",
    "remote_port": 80,
    "password": ["$default_passwd"],
    "log_level": 1,
    "ssl": {
        "cert": "$trojan_keys_dir/fullchain.pem",
        "key": "$trojan_keys_dir/privkey.pem",
        "key_password": "",
        "cipher": "ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256",
        "prefer_server_cipher": true,
        "alpn": [
            "http/1.1"
        ],
        "reuse_session": true,
        "session_ticket": false,
        "session_timeout": 600,
        "plain_http_response": "",
        "curves": "",
        "dhparam": ""
    },
    "tcp": {
        "prefer_ipv4": false,
        "no_delay": true,
        "keep_alive": true,
        "fast_open": false,
        "fast_open_qlen": 20
    }
}
EOF
	systemctl start trojan.service
	systemctl enable trojan.service

}


install_bbr(){
	if modprobe tcp_bbr; then
		echo "tcp_bbr" > /etc/modules-load.d/80-bbr.conf
	else 
		echo_yellow "BBR acceleration not supported"
		return 1
	fi
	cat /proc/sys/net/ipv4/tcp_available_congestion_control | egrep "bbr" &> /dev/null && \
	sysctl net.ipv4.tcp_congestion_control=bbr && \
	echo "net.ipv4.tcp_congestion_control = bbr" >  /etc/sysctl.d/80-bbr.conf && \
	echo_green "BBR enabled"
}

install_end_output(){
	echo_green "=========================================================================================="
	echo_green "domain: $domain, Port: 443 Password: $default_passwd]"
}



delete_check(){
	check_if_run_as_root
}

delete_installed_apps(){
	apt-get remove $apps_to_be_removed -y
	rm -rf /var/www/html /etc/letsencrypt/live/$domain $trojan_config_dir $certbot_certs_dir/${domain}*
}

delete_stop_service(){
	systemctl stop apache2.service trojan.service
}

echo_main_menu(){
	echo "1. Install trojan(If you ever executed [Install trojan] before, it's recommanded to run [Delete trojan] first)"
	echo "2. Delete trojan"
	echo "0. Exit"
}

echo_main_menu_and_take_user_choice(){
	while true; do
		echo_main_menu
		read -p "Input your choice" choice
		case $choice in
			1)
				install_trojan
				break
				;;
			2)
				delete_trojan
				break
				;;
			0)
				echo_yellow Exit...
				exit 0
				;;
			*)
				echo_red "invalid input!"
				;;
		esac
	done
}

main(){
	echo_head_warning
	echo_main_menu_and_take_user_choice
}
main

#!/usr/bin/env bash

# Exit on (non catched) error 
set -e

# Treat unset variables as an error when substituting
# set -u

# debuging
# set -x

# variables
project_dir=${PWD}
move_script_dir=$(dirname "$0")
wp_move_file="wp-move.yml"
wp_move_ignore=".wp-move-ignore"
wp_config_extra="wp-config-extra.php"
todays_date=$(date +%Y-%m-%d)
lock_file="wp-move-lock-file"
red_color_start='\033[1;31m'
red_color_end='\033[0m\n'

## function from https://gist.github.com/masukomi/e587aa6fd4f042496871
function parse_yaml {
	local prefix=$2
	local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
	sed -ne "s|^\($s\):|\1|" \
		-e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
		-e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p"  $1 |
	awk -F$fs '{
		indent = length($1)/2;
		vname[indent] = $2;
		for (i in vname) {if (i > indent) {delete vname[i]}}
		if (length($3) > 0) {
			vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
			printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, $2, $3);
		}
	}'
}

function verify_param() {
	if [ -z "${!1}" ]; then
		printf "${red_color_start}%s value not present in wp-move.yml, exiting...${red_color_end}" "${1}" >&2;
		exit 1
	fi
}

function remove_lock_file() {
	if [ -e "${project_dir}/${lock_file}" ]; then
		rm -f "${project_dir}/${lock_file}" || { 
			printf "${red_color_start}Cannot remove lock file: %s${red_color_end}" "${project_dir}/${lock_file}" >&2;
			exit 1
		}
	fi
}

## use rsync for ssh connection and lftp for ftp
function download_files() {    
    if [ "$production_protocol" = "ssh" ]; then
        if [ -r "${project_dir}/${wp_move_ignore}" ]; then
            rsync -rlpcP --exclude-from "${project_dir}/${wp_move_ignore}" -e "ssh -p $production_port" "$production_user"@"$production_host":"$production_path" "$wp_abspath"
        else
            rsync -rlpcP -e "ssh -p $production_port" "$production_user"@"$production_host":"$production_path" "$wp_abspath"
        fi

    elif [ "$production_protocol" = "ftp" ]; then

        if [ -r "${project_dir}/${wp_move_ignore}" ]; then
            lftp -e "set ssl:verify-certificate/$production_host no; mirror --no-perms --exclude-glob-from=${project_dir}/${wp_move_ignore} --verbose --use-pget-n=8 -c $production_path $wp_abspath; quit" -p "$production_port" --env-password -u "$production_user" "$production_host"
        else
            lftp -e "set ssl:verify-certificate/$production_host no; mirror --no-perms --verbose --use-pget-n=8 -c $production_path $wp_abspath; quit" -p "$production_port" --env-password -u "$production_user" "$production_host"
        fi
        # TODO - verify-certificate no - not secure
    fi
}

function export_db() {
    if [ "$production_protocol" = "ssh" ]; then

        if [ "$production_database_tool" = "wpcli" ]; then

            ssh "${production_user}@${production_host}" -p "$production_port" /bin/bash << REMOTE_CMD
                if ! [ -s ${production_path}/wp-cli.phar ]; then
                    cd $production_path
                    curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
                fi
REMOTE_CMD
            ssh "${production_user}@${production_host}" -p "$production_port" "php ${production_path}/wp-cli.phar db export - --path=${production_path} ${mysqldump_options}" > "${backup_dir}/${name}-${todays_date}.sql"
            # TODO - not sure we want to delete wp-cli.phar every time and download it again? wp-cli.phar living in root dir shouldn't be a problem
            ssh "${production_user}@${production_host}" -p "$production_port" "rm ${production_path}/wp-cli.phar"
        elif [ "$production_database_tool" = "mysqldump" ]; then
            # TODO - implement mysqldump
            printf "${red_color_start}production_database_tool: mysqldump not implemented${red_color_end}"
            remove_lock_file
            exit 1
            # najlatwiej byloby uzyc lokalnie mysqldump z opcja laczenia sie przez ssh i baze zapisać od razu lokalnie.. jednak może być to niebezpieczne, bo taka baza musiałaby umożliwiać łaczenie się z innych hostów
            # zatem trzeba będzie:
            # zczytać dane z wp-config.php
            # użyć "export" lub "set"... by było bezpiecznie?
            # zrobić dumpa i zapisać plik w sposób trudny do odgadnięcia
            # po zakonczonej sesji ssh, skopiować plik na komputer lokalny ( rsync, scp ) i usunąć zrzut z serwera produkcyjnego
        fi

    elif [ "$production_protocol" = "ftp" ]; then # wersja bez dostępu do ssh 

        lftp -e "set ssl:verify-certificate/$production_host no; put -O $production_path $move_script_dir/.wp-move.sh/wp-dump.php; quit" -p "$production_port" --env-password -u "$production_user" "$production_host"
        wget -O "${backup_dir}/${name}-${todays_date}.sql" "${production_url}/wp-dump.php"
        lftp -e "set ssl:verify-certificate/$production_host no; rm $production_path/wp-dump.php; quit" -p "$production_port" --env-password -u "$production_user" "$production_host"
    fi
}

function import_db() {
    $WP_CLI db create || true
    $WP_CLI db import "${backup_dir}/${name}-${todays_date}.sql" || {
        printf "${red_color_start}DB import error${red_color_end}"
        remove_lock_file
        exit 1
    }

    ## https://stackoverflow.com/a/45521875
    pattern='^(([[:alnum:]]+)://)?(([[:alnum:]]+)@)?([^:^@]+)(:([[:digit:]]+))?$'
    if [[ "$production_url" =~ $pattern ]]; then
        production_url_no_protocol=${BASH_REMATCH[5]}
    fi
    if [[ "$local_url" =~ $pattern ]]; then
        local_url_no_protocol=${BASH_REMATCH[5]}
    fi

    $WP_CLI search-replace "$production_url" "$local_url"
    $WP_CLI search-replace "$production_url_no_protocol" "$local_url_no_protocol"
}

function setup_wp_config() {
    # making sure we backed up wp-config.php
    if ! [ -s "${backup_dir}/wp-config.php" ]; then
        cp "${wp_abspath}/wp-config.php" "${backup_dir}/wp-config.php"
        # add to wp_move_ignore
        echo "wp-config.php" >> "${project_dir}/${wp_move_ignore}"
    fi

    table_prefix=$($WP_CLI config get table_prefix)
    DB_CHARSET=$($WP_CLI config get DB_CHARSET)
    DB_COLLATE=$($WP_CLI config get DB_COLLATE)

    if [ -s "${project_dir}/${wp_config_extra}" ]; then
        # we don't need first line ( <?php )
        wp_config_extra=$(tail -n +2 ${project_dir}/${wp_config_extra})
        $WP_CLI config create --dbname=${local_database_name} --dbuser=${local_database_user} --dbpass=${local_database_password} --dbhost=${local_database_host} --dbprefix=${table_prefix} --dbcharset=${DB_CHARSET} --dbcollate=${DB_COLLATE} --skip-check --force --extra-php <<EXTRA_PHP
    $wp_config_extra
EXTRA_PHP
    else
        $WP_CLI config create --dbname=${local_database_name} --dbuser=${local_database_user} --dbpass=${local_database_password} --dbhost=${local_database_host} --dbprefix=${table_prefix} --dbcharset=${DB_CHARSET} --dbcollate=${DB_COLLATE} --skip-check --force
    fi
}

function init() {

    overwrite_move_file='y'
    # if there is wp-move.yml file, make sure we want to overwrite it
    if [ -e "${project_dir}/${wp_move_file}" ]; then
        read -r -p "You already have ${wp_move_file} file, are You sure You want to overwrite it? (y/N) " overwrite_move_file
    fi

    case "$overwrite_move_file" in
        [Yy]* ) 
            cp "${move_script_dir}/.wp-move.sh/templates/${wp_move_file}" "${project_dir}/${wp_move_file}"
            # read -p "Some question about wp-move.yml config file?" some_var
            sed -i "s/%PROJECT_NAME%/${PWD##*/}/" "${project_dir}/${wp_move_file}"
            # nano "${project_dir}/${wp_move_file}"
            printf "%s file initialized\n" "${wp_move_file}"
    esac
    overwrite_move_ignore='y'
    # if there is wp-move.yml file, make sure we want to overwrite it
    if [ -e "${project_dir}/${wp_move_ignore}" ]; then
        read -r -p "You already have ${wp_move_ignore} file, are You sure You want to overwrite it? (y/N) " overwrite_move_ignore
    fi

    case "$overwrite_move_ignore" in
        [Yy]* ) 
            cp "${move_script_dir}/.wp-move.sh/templates/${wp_move_ignore}" "${project_dir}/${wp_move_ignore}"
            printf "%s file initialized\n" "${wp_move_ignore}"
    esac
    overwrite_config_extra='y'
    # if there is wp-move.yml file, make sure we want to overwrite it
    if [ -e "${project_dir}/${wp_config_extra}" ]; then
        read -r -p "You already have ${wp_config_extra} file, are You sure You want to overwrite it? (y/N) " overwrite_config_extra
    fi

    case "$overwrite_config_extra" in
        [Yy]* ) 
            cp "${move_script_dir}/.wp-move.sh/templates/${wp_config_extra}" "${project_dir}/${wp_config_extra}"
            printf "%s file initialized\n" "${wp_config_extra}"
            return ;;
        * ) 
            printf "OK, bye\n"
            return;;
    esac
}

function wm_help() {

    printf "\nUsage: wp-move [OPTION]\n\n"
    printf "Options (when no option is provided, then we do first 3 steps listed below)\n"
    printf " --files    sync files\n"
    printf " --config   generate wp-config.php file\n"
    printf " --db       sync database\n"
    printf " --init     generate wp-move.yml configuration file\n"
    printf " --php      print remote host php version\n"
    printf " --help     show this help\n\n"
}

function php_version() {

    version=$(ssh "${production_user}@${production_host}" -p "$production_port" /bin/bash << REMOTE_CMD
            php -r "echo PHP_VERSION;" | grep --only-matching --perl-regexp "7.\d+"
REMOTE_CMD
        )
    echo "${version}"
}

# maybe only help, init or php_version
case "$1" in 
    --help) 
        wm_help
        exit;;
    --init)
        init
        exit;;
    --php)
        php_version
        exit;;
esac

# config file is required
if [ -r "${project_dir}/${wp_move_file}" ]; then
    # TODO is eval secure?
    eval "$(parse_yaml ${wp_move_file})"
else
    printf "${red_color_start}No config file, or no permissions\n"
    printf "Please, provide one in %s ${red_color_end}" "${project_dir}/${wp_move_file}"
    exit 1;
fi

# making sure all necessary variables are set
verify_param name
verify_param local_path
verify_param local_backup
verify_param local_database_host
verify_param local_database_name
verify_param local_database_user
verify_param local_database_password
verify_param production_url
verify_param production_path
verify_param production_protocol
verify_param production_host
verify_param production_user
verify_param production_port
verify_param production_database_tool

wp_abspath="${project_dir}/${local_path}"
backup_dir="${project_dir}/${local_backup}"

if [ "$production_protocol" = "ftp" ]; then

    ## TODO check if is lftp installed
    verify_param production_password
    LFTP_PASSWORD=$production_password
    export LFTP_PASSWORD
fi

## catching Ctrl+C
trap remove_lock_file SIGINT SIGTERM

if [ -e "${project_dir}/${lock_file}" ]; then
	printf "${red_color_start}File lock found, another instance is running?${red_color_end}" >&2;
	exit 1
fi

touch "${project_dir}/${lock_file}" || {
    printf "${red_color_start}Cannot create lock file - exiting...${red_color_end}"  >&2;
	exit 1
}

wp_cli_command="wp"
if ! [ -x "$(command -v wp)" ]; then
    # not tested for wp-cli and wp-cli.phar
    wp_cli_command="wp-cli"
    if ! [ -x "$(command -v wp-cli)" ]; then
        curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
        wp_cli_command="php wp-cli.phar"
    fi
fi

WP_CLI="${wp_cli_command} --path=${wp_abspath}"

if [ -n "$1" ]; then

    case "$1" in 
    --files) 
        download_files;;
    --db)
        export_db
        setup_wp_config
        import_db;;
    --config)
        setup_wp_config;;
    **)
        wm_help;;
    esac
else
    download_files
    export_db
    setup_wp_config
    import_db
fi

remove_lock_file


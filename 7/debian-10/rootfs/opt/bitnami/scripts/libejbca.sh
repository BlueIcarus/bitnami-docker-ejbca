#!/bin/bash
#
# Bitnami EBJCA library

# shellcheck disable=SC1091

# Load Generic Libraries
. /opt/bitnami/scripts/libfs.sh
. /opt/bitnami/scripts/liblog.sh
. /opt/bitnami/scripts/libos.sh
. /opt/bitnami/scripts/libvalidations.sh

########################
# Validate settings in EJBCA_* env. variables
# Globals:
#   EJBCA_*
# Arguments:
#   None
# Returns:
#   None
#########################
ejbca_validate() {
    info "Validating settings in EJBCA_* env vars..."
    local error_code=0

    # Auxiliary functions
    print_validation_error() {
        error "$1"
        error_code=1
    }

    if [[ -z "$EJBCA_ADMIN_USERNAME" ]] || [[ -z "$EJBCA_ADMIN_PASSWORD" ]]; then
        print_validation_error "The EJBCA administrator user's credentials are mandatory. Set the environment variables EJBCA_ADMIN_USERNAME and EJBCA_ADMIN_PASSWORD with the EJBCA administrator user's credentials."
    fi

    if [[ -n "$EJBCA_SERVER_CERT_FILE" ]] && [[ -z "$EJBCA_SERVER_CERT_PASSWORD" ]]; then
        print_validation_error "If you indicate a Certificate file, you need to provide its password in EJBCA_SERVER_CERT_PASSWORD."
    fi

    if [[ -z "$EJBCA_DATABASE_HOST" ]]; then
        print_validation_error "The EJBCA database host is mandatory. Set the environment variables EJBCA_DATABASE_HOST."
    fi

    if [[ -z "$EJBCA_DATABASE_PORT" ]]; then
        print_validation_error "The EJBCA database port is mandatory. Set the environment variables EJBCA_DATABASE_PORT."
    fi

    if [[ -z "$EJBCA_DATABASE_USERNAME" ]]; then
        print_validation_error "The EJBCA database username is mandatory. Set the environment variables EJBCA_DATABASE_USERNAME."
    fi

    if [[ -z "$EJBCA_DATABASE_PASSWORD" ]]; then
        print_validation_error "The EJBCA database password is mandatory. Set the environment variables EJBCA_DATABASE_PASSWORD."
    fi

    [[ "$error_code" -eq 0 ]] || exit "$error_code"
}

########################
# Run wildfly CLI
# Globals:
#   EJBCA_*
# Arguments:
#   None
# Returns:
#   None
#########################
ejbca_wildfly_command() {
    "$EJBCA_WILDFLY_BIN_DIR"/jboss-cli.sh --connect -u="$EJBCA_WILDFLY_ADMIN_USER" -p="$EJBCA_WILDFLY_ADMIN_PASSWORD" "$1"
}

########################
# Wait until wildfly is ready
# Globals:
#   EJBCA_*
# Arguments:
#   None
# Returns:
#   None
#########################
wait_for_wildfly() {
    retry_while wildfly_not_ready
}

########################
# Check if the console is not ready
# Globals:
#   EJBCA_*
# Arguments:
#   None
# Returns:
#   None
#########################
wildfly_not_ready() {
    local status

    status=$(ejbca_wildfly_command ":read-attribute(name=server-state)" | grep "result")
    [[ "$status" =~ "running" ]] && return 0 || return 1
}

########################
# Configure Wildfly
# Globals:
#   EJBCA_*
# Arguments:
#   None
# Returns:
#   None
#########################
ejbca_configure_wildfly() {
    info "Creating data source"
    local -r pluginJar="$(basename "$EJBCA_WILDFLY_DEPLOY_DIR"/mariadb*)"
    ejbca_wildfly_command "data-source add --name=ejbcads --driver-name=\"${pluginJar}\" --connection-url=\"jdbc:mysql://${EJBCA_DATABASE_HOST}:${EJBCA_DATABASE_PORT}/${EJBCA_DATABASE_NAME}\" --jndi-name=\"java:/EjbcaDS\" --use-ccm=true --driver-class=\"org.mariadb.jdbc.Driver\" --user-name=\"${EJBCA_DATABASE_USERNAME}\" --password=\"${EJBCA_DATABASE_PASSWORD}\" --validate-on-match=true --background-validation=false --prepared-statements-cache-size=50 --share-prepared-statements=true --min-pool-size=5 --max-pool-size=150 --pool-prefill=true --transaction-isolation=TRANSACTION_READ_COMMITTED --check-valid-connection-sql=\"select 1;\""
    ejbca_wildfly_command ":reload"
    wait_for_wildfly

    info "Configure WildFly Remoting"
    ejbca_wildfly_command "/subsystem=remoting/http-connector=http-remoting-connector:write-attribute(name=connector-ref,value=remoting)"
    ejbca_wildfly_command "/socket-binding-group=standard-sockets/socket-binding=remoting:add(port=4447,interface=management)"
    ejbca_wildfly_command "/subsystem=undertow/server=default-server/http-listener=remoting:add(socket-binding=remoting,enable-http2=true)"
    ejbca_wildfly_command "/subsystem=infinispan/cache-container=ejb:remove()"
    ejbca_wildfly_command "/subsystem=infinispan/cache-container=server:remove()"
    ejbca_wildfly_command "/subsystem=infinispan/cache-container=web:remove()"
    ejbca_wildfly_command "/subsystem=ejb3/cache=distributable:remove()"
    ejbca_wildfly_command "/subsystem=ejb3/passivation-store=infinispan:remove()"
    ejbca_wildfly_command ":reload"
    wait_for_wildfly

    info "Configure logging"
    ejbca_wildfly_command "/subsystem=logging/logger=org.ejbca:add(level=INFO)"
    ejbca_wildfly_command "/subsystem=logging/logger=org.cesecore:add(level=INFO)"

    info "Remove the ExampleDS DataSource"
    ejbca_wildfly_command '/subsystem=ee/service=default-bindings:remove()'
    ejbca_wildfly_command 'data-source remove --name=ExampleDS'
    ejbca_wildfly_command ':reload'
    wait_for_wildfly

    info "Configure email"
    ejbca_wildfly_command "/socket-binding-group=standard-sockets/remote-destination-outbound-socket-binding=ejbca-mail-smtp:add(port=\"${EJBCA_SMTP_PORT}\", host=\"${EJBCA_SMTP_HOST}\")"
    ejbca_wildfly_command "/subsystem=mail/mail-session=\"java:/EjbcaMail\":add(jndi-name=java:/EjbcaMail, from=${EJBCA_SMTP_FROM_ADDRESS})"
    if [[ ! -z "$EJBCA_SMTP_USERNAME" ]]; then
        ejbca_wildfly_command "/subsystem=mail/mail-session=\"java:/EjbcaMail\"/server=smtp:add(outbound-socket-binding-ref=ejbca-mail-smtp, tls=${EJBCA_SMTP_TLS}, username=\"${EJBCA_SMTP_USERNAME}\", password=\"${EJBCA_SMTP_PASSWORD}\")"
    else
        ejbca_wildfly_command "/subsystem=mail/mail-session=\"java:/EjbcaMail\"/server=smtp:add(outbound-socket-binding-ref=ejbca-mail-smtp, tls=${EJBCA_SMTP_TLS})"
    fi
    ejbca_wildfly_command ':reload'
    wait_for_wildfly

    info "Configure redirection"
    ejbca_wildfly_command '/subsystem=undertow/server=default-server/host=default-host/location="\/":remove()'
    ejbca_wildfly_command '/subsystem=undertow/configuration=handler/file=welcome-content:remove()'
    ejbca_wildfly_command ':reload'
    ejbca_wildfly_command '/subsystem=undertow/configuration=filter/rewrite=redirect-to-app:add(redirect=true,target="/ejbca/")'
    ejbca_wildfly_command "/subsystem=undertow/server=default-server/host=default-host/filter-ref=redirect-to-app:add(predicate=\"method(GET) and not path-prefix('/ejbca/','/crls','/certificates','/.well-known/') and not equals({%{LOCAL_PORT}, 4447})\")"
    ejbca_wildfly_command ':reload'
    wait_for_wildfly
}

########################
# Configure wildfly https parameters
# Globals:
#   EJBCA_*
# Arguments:
#   None
# Returns:
#   None
#########################
ejbca_configure_wildfly_https() {
    info "HTTP(S) Listener Configuration"
    ejbca_wildfly_command "/subsystem=undertow/server=default-server/http-listener=default:remove()"
    ejbca_wildfly_command "/subsystem=undertow/server=default-server/https-listener=https:remove()"
    ejbca_wildfly_command "/socket-binding-group=standard-sockets/socket-binding=http:remove()"
    ejbca_wildfly_command "/socket-binding-group=standard-sockets/socket-binding=https:remove()"
    ejbca_wildfly_command ":reload"
    wait_for_wildfly

    info "Add New Interfaces and Sockets"
    ejbca_wildfly_command '/interface=http:add(inet-address="0.0.0.0")'
    ejbca_wildfly_command '/interface=httpspub:add(inet-address="0.0.0.0")'
    ejbca_wildfly_command '/interface=httpspriv:add(inet-address="0.0.0.0")'
    ejbca_wildfly_command "/socket-binding-group=standard-sockets/socket-binding=http:add(port=\"$EJBCA_HTTP_PORT_NUMBER\",interface=\"http\")"
    ejbca_wildfly_command '/socket-binding-group=standard-sockets/socket-binding=httpspub:add(port="8442",interface="httpspub")'
    ejbca_wildfly_command "/socket-binding-group=standard-sockets/socket-binding=httpspriv:add(port=\"$EJBCA_HTTPS_PORT_NUMBER\",interface=\"httpspriv\")"

    info "Configure TLS"
    ejbca_wildfly_command "/subsystem=elytron/key-store=httpsKS:add(path=\"keystore.jks\",relative-to=jboss.server.config.dir,credential-reference={clear-text=\"$EJBCA_KEYSTORE_PASSWORD\"},type=JKS)"
    ejbca_wildfly_command "/subsystem=elytron/key-store=httpsTS:add(path=\"truststore.jks\",relative-to=jboss.server.config.dir,credential-reference={clear-text=\"$EJBCA_TRUSTSTORE_PASSWORD\"},type=JKS)"
    ejbca_wildfly_command "/subsystem=elytron/key-manager=httpsKM:add(key-store=httpsKS,algorithm=\"SunX509\",credential-reference={clear-text=\"$EJBCA_KEYSTORE_PASSWORD\"})"
    ejbca_wildfly_command '/subsystem=elytron/trust-manager=httpsTM:add(key-store=httpsTS)'
    ejbca_wildfly_command '/subsystem=elytron/server-ssl-context=httpspub:add(key-manager=httpsKM,protocols=["TLSv1.2"])'
    ejbca_wildfly_command '/subsystem=elytron/server-ssl-context=httpspriv:add(key-manager=httpsKM,protocols=["TLSv1.2"],trust-manager=httpsTM,need-client-auth=false,authentication-optional=true,want-client-auth=true)'

    info "Add HTTP(S) and AJP Listeners"
    ejbca_wildfly_command '/subsystem=undertow/server=default-server/http-listener=http:add(socket-binding="http", redirect-socket="httpspriv")'
    ejbca_wildfly_command '/subsystem=undertow/server=default-server/https-listener=httpspub:add(socket-binding="httpspub", ssl-context="httpspub", max-parameters=2048)'
    ejbca_wildfly_command '/subsystem=undertow/server=default-server/https-listener=httpspriv:add(socket-binding="httpspriv", ssl-context="httpspriv", max-parameters=2048)'
    ejbca_wildfly_command "/subsystem=undertow/server=default-server/ajp-listener=ajp-listener:add(socket-binding=ajp, scheme=https, enabled=true)"
    ejbca_wildfly_command ':reload'
    wait_for_wildfly

    info "HTTP Protocol Behavior Configuration"
    ejbca_wildfly_command '/system-property=org.apache.catalina.connector.URI_ENCODING:add(value="UTF-8")'
    ejbca_wildfly_command '/system-property=org.apache.catalina.connector.USE_BODY_ENCODING_FOR_QUERY_STRING:add(value=true)'
    ejbca_wildfly_command '/system-property=org.apache.tomcat.util.buf.UDecoder.ALLOW_ENCODED_SLASH:add(value=true)'
    ejbca_wildfly_command '/system-property=org.apache.tomcat.util.http.Parameters.MAX_COUNT:add(value=2048)'
    ejbca_wildfly_command '/system-property=org.apache.catalina.connector.CoyoteAdapter.ALLOW_BACKSLASH:add(value=true)'
    ejbca_wildfly_command '/subsystem=webservices:write-attribute(name=wsdl-host, value=jbossws.undefined.host)'
    ejbca_wildfly_command '/subsystem=webservices:write-attribute(name=modify-wsdl-address, value=true)'
    ejbca_wildfly_command ':reload'
    wait_for_wildfly
}

########################
# Start wildfly in background
# Globals:
#   EJBCA_*
# Arguments:
#   None
# Returns:
#   None
#########################
ejbca_start_wildfly_bg() {
    local -r exec="$EJBCA_WILDFLY_BIN_DIR"/standalone.sh
    local args=("-b" "127.0.0.1")

    info "Starting wildfly..."

    if ! [[ -f "$EJBCA_WILDFLY_PID_FILE" ]]; then
        if [[ "${BITNAMI_DEBUG:-false}" = true ]]; then
            "${exec}" "${args[@]}" &
        else
            "${exec}" "${args[@]}" >/dev/null 2>&1 &
        fi
    fi
}

######################
# Stop wildfly
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#########################
ejbca_stop_wildfly() {
    info "Stopping wildfly..."
    ejbca_wildfly_command ":shutdown"
}

ejbca_custom_scripts() {
    info "Running custom scripts..."
    FILES=/bitnami/custom-scripts/*
    for f in ${FILES}
    do
        echo "Executing file: ${f}"
        bash "${f}"
    done
}

#######################
# Create wildfly management user
# Globals:
#   EJBCA_*
# Arguments:
#   None
# Returns:
#   None
#########################
ejbca_create_management_user() {
    info "Creating wildfly management user..."

    "$EJBCA_WILDFLY_BIN_DIR"/add-user.sh -u "$EJBCA_WILDFLY_ADMIN_USER" -p "$EJBCA_WILDFLY_ADMIN_PASSWORD" -s
}

#######################
# Deploy package in wildfly
# Globals:
#   EJBCA_*
# Arguments:
#   None
# Returns:
#   None
#########################
ejbca_wildfly_deploy() {
    deployed_file="$EJBCA_WILDFLY_DEPLOY_DIR"/$(basename "$1").deployed

    if [[ ! -f "$deployed_file" ]]; then
        cp "$1" "$EJBCA_WILDFLY_DEPLOY_DIR"/
        retry_while "ls $deployed_file" 2>/dev/null
        info "Deployment done"
    else
        info "Already deployed"
    fi
}

########################
# Check if the console is not ready
# Globals:
#   EJBCA_*
# Arguments:
#   None
# Returns:
#   None
#########################
database_not_ready() {
    echo "select 1" | debug_execute mysql -u"$EJBCA_DATABASE_USERNAME" -p"$EJBCA_DATABASE_PASSWORD" -h"$EJBCA_DATABASE_HOST" -P"$EJBCA_DATABASE_PORT" "$EJBCA_DATABASE_NAME"
}

########################
# Check if the console is not ready
# Globals:
#   EJBCA_*
# Arguments:
#   None
# Returns:
#   None
#########################
ejbca_create_database() {
    info "Creating database tables and indexes"

    # Wait for the database to be ready
    retry_while database_not_ready

    # Create database structure
    mysql -u"$EJBCA_DATABASE_USERNAME" -p"$EJBCA_DATABASE_PASSWORD" -h"$EJBCA_DATABASE_HOST" -P"$EJBCA_DATABASE_PORT" "$EJBCA_DATABASE_NAME" <"$EJBCA_DB_SCRIPT_TABLES"
    mysql -u"$EJBCA_DATABASE_USERNAME" -p"$EJBCA_DATABASE_PASSWORD" -h"$EJBCA_DATABASE_HOST" -P"$EJBCA_DATABASE_PORT" "$EJBCA_DATABASE_NAME" <"$EJBCA_DB_SCRIPT_INDEXES"
}

########################
# Generate CA
# Globals:
#   EJBCA_*
# Arguments:
#   None
# Returns:
#   None
#########################
ejbca_generate_ca() {
    local ejbca_ca
    local existing_management_ca
    local instance_hostname
    local end_entity_name
    local -r instance_hostname="$(hostname --fqdn)"

    info "Generating CA"
    ejbca_ca="$(ejbca_command ca listcas 2>&1)"
    if ! grep -q 'CA Name: ' <<<"$ejbca_ca"; then
        info "Init CA"
        ejbca_command ca init \
            --dn "CN=$EJBCA_CA_NAME,$EJBCA_BASE_DN" \
            --caname "$EJBCA_CA_NAME" \
            --tokenType "soft" \
            --tokenPass "null" \
            --keytype "RSA" \
            --keyspec "3072" \
            -v "3652" \
            --policy "null" \
            -s "SHA256WithRSA" \
            -type "x509"

        info "Add superadmin user"
        ejbca_command ra addendentity \
            --username "$EJBCA_ADMIN_USERNAME" \
            --dn "\"CN=SuperAdmin,$EJBCA_BASE_DN\"" \
            --caname "$EJBCA_CA_NAME" \
            --type 1 \
            --token P12 \
            --password "$EJBCA_ADMIN_PASSWORD"
    fi

    ejbca_ca="$(ejbca_command ca listcas 2>&1)"
    if grep -q "CA Name: $EJBCA_CA_NAME" <<<"$ejbca_ca"; then
        existing_management_ca="$(grep "CA Name: $EJBCA_CA_NAME" <<<"$ejbca_ca" | sed 's/.*CA Name: //g')"

        if [[ "$existing_management_ca" == "$EJBCA_CA_NAME" ]]; then

            end_entity_name="$instance_hostname"
            if [ "$instance_hostname" == "ejbca" ]; then
                # Avoid conflicts with the default EJBCA EJB CLI end entity "ejbca"
                end_entity_name="ejbca-instance-tls"
            fi

            info "Add RA Entity"
            ejbca_command ra addendentity \
                --username "$end_entity_name" \
                --dn "\"CN=$instance_hostname,$EJBCA_BASE_DN\"" \
                --caname "$EJBCA_CA_NAME" \
                --type 1 \
                --token JKS \
                --password "$EJBCA_KEYSTORE_PASSWORD" \
                --altname "dnsName=$instance_hostname" \
                --certprofile SERVER

            info "Set RA status to new"
            ejbca_command ra setendentitystatus \
                --username "$end_entity_name" \
                -S 10

            info "Set RA entity password"
            ejbca_command ra setclearpwd \
                --username "$end_entity_name" \
                --password "$EJBCA_KEYSTORE_PASSWORD"

            info "Export entity certificate"
            ejbca_command batch \
                --username "$end_entity_name" \
                -dir "$EJBCA_TMP_DIR/"

            mv "$EJBCA_TMP_DIR/$end_entity_name.jks" "$EJBCA_TEMP_KEYSTORE_FILE"

            ejbca_command roles addrolemember \
                --namespace "" \
                --role "Super Administrator Role" \
                --caname "$EJBCA_CA_NAME" \
                --with "CertificateAuthenticationToken:WITH_COMMONNAME" \
                --value "SuperAdmin" \
                --description "Initial RoleMember."
        fi
    fi
}

########################
# EJBCA CLI
# Globals:
#   EJBCA_*
# Arguments:
#   None
# Returns:
#   None
#########################
ejbca_command() {
    "$EJBCA_BIN_DIR"/ejbca.sh "$@" 2>&1
}

########################
# Keytool wrapper
# Globals:
#   None
# Arguments:
#   None
# Returns:
#   None
#########################
ejbca_keytool_command() {
    keytool "$@" 2>&1
}

########################
# Generate keystores
# Globals:
#   EJBCA_*
# Arguments:
#   None
# Returns:
#   None
#########################
ejbca_create_truststore() {
    local line
    local ejbca_ca
    local ca_list

    info "Load the CAs in the trustkeystore"
    ejbca_ca="$(ejbca_command ca listcas 2>&1)"
    if grep -q 'CA Name: ' <<<"$ejbca_ca"; then
        ca_list=("$(grep 'CA Name: ' <<<"$ejbca_ca" | sed 's/.*CA Name: //g')")
        for line in "${ca_list[@]}"; do
            ejbca_command ca getcacert \
                --caname "$line" \
                -f "$EJBCA_TEMP_CERT" \
                -der

            if [ -f "$EJBCA_TEMP_CERT" ]; then
                ejbca_keytool_command -alias "$line" \
                    -import -trustcacerts \
                    -file "$EJBCA_TEMP_CERT" \
                    -keystore "$EJBCA_TEMP_TRUSTSTORE_FILE" \
                    -storepass "$EJBCA_TRUSTSTORE_PASSWORD" \
                    -noprompt
                rm "$EJBCA_TEMP_CERT"
            fi
        done
    fi
}

########################
# Generate keystores
# Globals:
#   EJBCA_*
# Arguments:
#   None
# Returns:
#   None
#########################
ejbca_persist_keystores() {
    info "Persisting keystores"

    # Persist keystores and passwords
    mv "$EJBCA_TEMP_TRUSTSTORE_FILE" "$EJBCA_TRUSTSTORE_FILE"
    mv "$EJBCA_TEMP_KEYSTORE_FILE" "$EJBCA_KEYSTORE_FILE"
    echo "$EJBCA_KEYSTORE_PASSWORD" >"$EJBCA_KEYSTORE_PASSWORD_FILE"
    echo "$EJBCA_TRUSTSTORE_PASSWORD" >"$EJBCA_TRUSTSTORE_PASSWORD_FILE"
    echo "$EJBCA_WILDFLY_ADMIN_PASSWORD" >"$EJBCA_WILDFLY_ADMIN_PASSWORD_FILE"

    # Provide keystores to wildfly
    [[ ! -e "$EJBCA_WILDFLY_TRUSTSTORE_FILE" ]] && ln -s "$EJBCA_TRUSTSTORE_FILE" "$EJBCA_WILDFLY_TRUSTSTORE_FILE"
    [[ ! -e "$EJBCA_WILDFLY_KEYSTORE_FILE" ]] && ln -s "$EJBCA_KEYSTORE_FILE" "$EJBCA_WILDFLY_KEYSTORE_FILE"
}

########################
# Check if there is data persisted
# Globals:
#   EJBCA_*
# Arguments:
#   None
# Returns:
#   None
#########################
ejbca_is_persisted() {
    [[ -f "$EJBCA_TRUSTSTORE_FILE" ]] && [[ -f "$EJBCA_KEYSTORE_FILE" ]] && [[ -f "$EJBCA_TRUSTSTORE_PASSWORD_FILE" ]] && [[ -f "$EJBCA_KEYSTORE_PASSWORD_FILE" ]] && [[ -f "$EJBCA_WILDFLY_ADMIN_PASSWORD_FILE" ]]
}

########################
# Load persisted passwords
# Globals:
#   EJBCA_*
# Arguments:
#   None
# Returns:
#   None
#########################
ejbca_load_persisted() {
    info "Loading persisted keystore passwords"

    read -r EJBCA_KEYSTORE_PASSWORD <"$EJBCA_KEYSTORE_PASSWORD_FILE"
    read -r EJBCA_TRUSTSTORE_PASSWORD <"$EJBCA_TRUSTSTORE_PASSWORD_FILE"
    read -r EJBCA_WILDFLY_ADMIN_PASSWORD <"$EJBCA_WILDFLY_ADMIN_PASSWORD_FILE"

    # Provide keystores to wildfly
    info "Placing widlfly keystores"
    [[ ! -e "$EJBCA_WILDFLY_TRUSTSTORE_FILE" ]] && ln -s "$EJBCA_TRUSTSTORE_FILE" "$EJBCA_WILDFLY_TRUSTSTORE_FILE"
    [[ ! -e "$EJBCA_WILDFLY_KEYSTORE_FILE" ]] && ln -s "$EJBCA_KEYSTORE_FILE" "$EJBCA_WILDFLY_KEYSTORE_FILE"
}

########################
# Sets java_opts
# Globals:
#   EJBCA_*
# Arguments:
#   None
# Returns:
#   None
#########################
ejba_set_java_opts() {
    cat >>"$EJBCA_WILDFLY_STANDALONE_CONF_FILE" <<EOF
JAVA_OPTS="$JAVA_OPTS -Dhttpserver.external.privhttps=$EJBCA_HTTPS_ADVERTISED_PORT_NUMBER"
EOF
}

########################
# Ensure EJBCA is initialized
# Globals:
#   EJBCA_*
# Arguments:
#   None
# Returns:
#   None
#########################
ejbca_initialize() {
    info "Initializing EJBCA..."

    # Configuring permissions for tmp, logs and data folders
    am_i_root && configure_permissions_ownership "$EJBCA_TMP_DIR $EJBCA_LOG_DIR" -u "$EJBCA_DAEMON_USER" -g "$EJBCA_DAEMON_GROUP"
    am_i_root && configure_permissions_ownership "$EJBCA_DATA_DIR" -u "$EJBCA_DAEMON_USER" -g "$EJBCA_DAEMON_GROUP" -d "755" -f "644"

    ensure_dir_exists "$EJBCA_DATA_DIR"

    if [[ -f "$EJBCA_TEMP_KEYSTORE_FILE" ]]; then rm -f "$EJBCA_TEMP_KEYSTORE_FILE"; fi
    if [[ -f "$EJBCA_TEMP_TRUSTSTORE_FILE" ]]; then rm -f "$EJBCA_TEMP_TRUSTSTORE_FILE"; fi

    if ! ejbca_is_persisted; then
        info "Deploying EJBCA from scratch"

        # Generate random passwords
        EJBCA_TRUSTSTORE_PASSWORD="${EJBCA_TRUSTSTORE_PASSWORD:-$(generate_random_string -t alphanumeric)}"
        export EJBCA_TRUSTSTORE_PASSWORD
        EJBCA_KEYSTORE_PASSWORD="${EJBCA_KEYSTORE_PASSWORD:-$(generate_random_string -t alphanumeric)}"
        export EJBCA_KEYSTORE_PASSWORD
        EJBCA_WILDFLY_ADMIN_PASSWORD="${EJBCA_WILDFLY_ADMIN_PASSWORD:-$(generate_random_string -t alphanumeric)}"
        export EJBCA_WILDFLY_ADMIN_PASSWORD
        EJBCA_BASE_DN="${EJBCA_BASE_DN:-O=Example CA,C=SE,UID=c-$(generate_random_string -t alphanumeric)}"
        export EJBCA_BASE_DN

        # Check if external keystore
        if [[ -f "$EJBCA_SERVER_CERT_FILE" && -n "$EJBCA_SERVER_CERT_PASSWORD" ]]; then
            info "Using provided server TLS keystore"
            ejbca_keytool_command -importkeystore -noprompt \
                -srckeystore "$EJBCA_SERVER_CERT_FILE" \
                -srcstorepass "$EJBCA_SERVER_CERT_PASSWORD" \
                -destkeystore "$EJBCA_TEMP_KEYSTORE_FILE" \
                -deststorepass "$EJBCA_KEYSTORE_PASSWORD" \
                -deststoretype jks
        fi

        ejbca_create_database
    else
        info "Persisted data detected"

        ejbca_load_persisted
    fi

    ejba_set_java_opts

    ejbca_create_management_user
    ejbca_start_wildfly_bg
    wait_for_wildfly
    ejbca_configure_wildfly

    info "Deploying EJBCA application"
    ejbca_wildfly_deploy "$EJBCA_EAR_FILE"

    if ! ejbca_is_persisted; then
        ejbca_generate_ca
        ejbca_create_truststore
        ejbca_persist_keystores
    fi

    ejbca_configure_wildfly_https

    ejbca_custom_scripts

    ejbca_stop_wildfly

}

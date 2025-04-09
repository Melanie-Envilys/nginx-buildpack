warn() {
  echo " !     $*" >&2
}

error() {
  echo " !     $*" >&2
  exit 1
}

status() {
  echo "-----> $*"
}

protip() {
  echo
  echo "TIP: $*" | indent
  echo
}

# sed -l basically makes sed replace and buffer through stdin to stdout
# so you get updates while the command runs and dont wait for the end
# e.g. npm install | indent
indent() {
  c='s/^/       /'
  case $(uname) in
    Darwin) sed -l "$c";; # mac/bsd sed: -l buffers on line boundaries
    *)      sed -u "$c";; # unix/gnu sed: -u unbuffered (arbitrary) chunks of data
  esac
}

export_env_dir() {
  env_dir=$1
  blacklist_regex=${3:-'^(PATH|GIT_DIR|CPATH|CPPATH|LD_PRELOAD|LIBRARY_PATH|LD_LIBRARY_PATH)$'}
  if [ -d "$env_dir" ]; then
    for e in $(ls $env_dir); do
      echo "$e" | grep -qvE "$blacklist_regex" &&
      export "$e=$(cat $env_dir/$e)"
      :
    done
  fi
}

function fetch_custom() {
  status "Bundling Nginx ${NGINX_VERSION} with PCRE2 support"

  # Download from nginx.org official packages repository (stable branch)
  NGINX_PKG_URL="https://nginx.org/packages/ubuntu/pool/nginx/n/nginx/nginx_${NGINX_VERSION}-1~jammy_amd64.deb"
  NGINX_DEB="/tmp/nginx.deb"

  status "Downloading NGINX ${NGINX_VERSION} from ${NGINX_PKG_URL}"
  curl -L "$NGINX_PKG_URL" -o "$NGINX_DEB" || {
    status "Stable package download failed, trying mainline"
    NGINX_PKG_URL="https://nginx.org/packages/mainline/ubuntu/pool/nginx/n/nginx/nginx_${NGINX_VERSION}-1~jammy_amd64.deb"
    curl -L "$NGINX_PKG_URL" -o "$NGINX_DEB" || {
      status "ERROR: Failed to download NGINX ${NGINX_VERSION}"
      exit 1
    }
  }

  # Extract the DEB package
  mkdir -p /tmp/nginx-extract "${HOME}/vendor/nginx"
  dpkg -x "$NGINX_DEB" /tmp/nginx-extract || {
    status "ERROR: Failed to extract NGINX package"
    exit 1
  }

  # Copy necessary files
  status "Installing NGINX binaries"
  mkdir -p "${HOME}/vendor/nginx/sbin" "${HOME}/vendor/nginx/conf" "${HOME}/vendor/nginx/logs"
  cp -r /tmp/nginx-extract/usr/sbin/nginx "${HOME}/vendor/nginx/sbin/"
  cp -r /tmp/nginx-extract/etc/nginx/* "${HOME}/vendor/nginx/conf/" || true
  chmod +x "${HOME}/vendor/nginx/sbin/nginx"

# Check if this NGINX binary is built with PCRE2
status "Checking NGINX configuration and PCRE version"
"${HOME}/vendor/nginx/sbin/nginx" -V 2>&1 | indent

if "${HOME}/vendor/nginx/sbin/nginx" -V 2>&1 | grep -q 'with-pcre='; then
  status "WARNING: NGINX binary appears to be built with custom PCRE path, likely PCRE1"
  status "Checking for PCRE2 symbols in binary"
  strings "${HOME}/vendor/nginx/sbin/nginx" | grep -i "pcre2" | head -5 | indent
  
  # We need to download and install matching NJS module for PCRE1
  status "Will try to use NJS module compatible with PCRE1"
elif "${HOME}/vendor/nginx/sbin/nginx" -V 2>&1 | grep -q 'PCRE2'; then
  status "Confirmed: NGINX is built with PCRE2"
else
  status "WARNING: NGINX binary may not have explicit PCRE2 information"
  status "Checking for PCRE symbols in binary"
  strings "${HOME}/vendor/nginx/sbin/nginx" | grep -i "pcre" | head -5 | indent
fi

}

function fetch_engine_package() {
  local engine="$1"
  local version="$2"
  local location="$3"
  local package="${engine}-${version}"

  mkdir -p "$location"

  local checksum_url="${VENDOR_URL}/package/${package}.md5"
  local package_url="${VENDOR_URL}/package/${package}.tgz"
  local checksum=$(curl --fail --retry 3 --retry-delay 2 --connect-timeout 3 --max-time 30 "$checksum_url" 2> /dev/null || echo "")
  local cache_checksum=""

  if [ -f "$CACHE_DIR/package/${package}.md5" ]; then
    local cache_checksum=$(cat "$CACHE_DIR/package/${package}.md5")
  fi

  mkdir -p "$CACHE_DIR/package/$(dirname "$package")"

  if [ "$cache_checksum" != "$checksum" ] || [ -z "$checksum" ] || [ ! -f "$CACHE_DIR/package/${package}.tgz" ]; then
    status "Downloading ${engine} ${version}"
    
    # Try the primary URL first
    if ! curl --fail --retry 3 --retry-delay 2 --connect-timeout 3 --max-time 30 "$package_url" -L -s > "$CACHE_DIR/package/${package}.tgz"; then
      status "Primary download failed, trying alternative sources"
      # Try nginx.org directly (if it's the nginx engine)
      if [ "$engine" = "nginx" ]; then
        status "Trying nginx.org directly"
        if ! curl --fail --retry 3 --retry-delay 2 --connect-timeout 3 --max-time 30 "https://nginx.org/download/${package}.tar.gz" -L -s > "$CACHE_DIR/package/${package}.tgz"; then
          status "ERROR: Failed to download ${engine} ${version} from all sources"
          exit 1
        fi
      else
        status "ERROR: Failed to download ${engine} ${version} from all sources"
        exit 1
      fi
    fi
    
    # Update checksum if we have one
    if [ ! -z "$checksum" ]; then
      echo "$checksum" > "$CACHE_DIR/package/${package}.md5"
    else
      # Generate our own checksum if we couldn't get the official one
      md5sum "$CACHE_DIR/package/${package}.tgz" | cut -d ' ' -f 1 > "$CACHE_DIR/package/${package}.md5"
    fi
  else
    echo "Checksums match. Fetching from cache."
  fi

  status "Extracting ${engine} ${version}"
  tar --overwrite --extract --gzip \
      --file="${CACHE_DIR}/package/${package}.tgz" \
      --directory="${location}" || {
    status "ERROR: Failed to extract ${engine} ${version}"
    rm -f "$CACHE_DIR/package/${package}.tgz" "$CACHE_DIR/package/${package}.md5"
    exit 1
  }
}

init_log_plex() {
  log_files="$@"
  for log_file in ${log_files[@]}; do
    echo "mkdir -p `dirname ${log_file}`"
  done
  for log_file in ${log_files[@]}; do
    echo "touch \"\$basedir/${log_file}\""
  done
}

tail_log_plex() {
  log_files="$@"
  for log_file in ${log_files[@]}; do
    echo "tail -n 0 -qF --pid=\$\$ \"\$basedir/${log_file}\" &"
  done
}


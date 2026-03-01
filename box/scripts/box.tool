#!/system/bin/sh

scripts_dir="${0%/*}"

user_agent="box_for_root"
source /data/adb/box/settings.ini

TOOL_LOG="/data/adb/box/run/tool.log"
busybox mkdir -p "$(dirname "$TOOL_LOG")"
box_log="$TOOL_LOG"

setup_github_api() {
  rev1="busybox wget --no-check-certificate -qO-"
  if which curl >/dev/null; then
    rev1="curl --insecure -sL"
  fi
  if [ -n "$githubtoken" ]; then
    if which curl >/dev/null; then
      rev1="curl --insecure -sL -H \"Authorization: token ${githubtoken}\""
    else
      rev1="busybox wget --no-check-certificate -qO- --header=\"Authorization: token ${githubtoken}\""
    fi
    log Info "GitHub Token 已配置，将使用认证访问 GitHub API"
  else
    log Info "未配置 GitHub Token，将使用匿名访问 GitHub API"
  fi
}

mask_url() {
  local u="$1"
  echo "$u" | sed -E 's#^([a-zA-Z][a-zA-Z0-9+.-]*://)?([^/]+).*$#\1\2/***#'
}

divider() {
  local line="----------------------------------------"
  [ -n "$box_log" ] && echo "$line" >> "$box_log"
}
trap divider EXIT
log Info "执行命令: $0 $@"

upfile() {
  local file="$1"
  local update_url="$2"
  local custom_ua="$3"
  local current_ua
  [ -n "${custom_ua}" ] && current_ua="${custom_ua}" || current_ua="${user_agent}"

  local file_bak="${file}.bak"
  [ -f "${file}" ] && mv "${file}" "${file_bak}"

  if [ "${use_ghproxy}" = "true" ] && [[ "${update_url}" == @(https://github.com/*|https://raw.githubusercontent.com/*|https://gist.github.com/*|https://gist.githubusercontent.com/*) ]]; then
    update_url="${url_ghproxy}/${update_url}"
  fi

  local log_url="${update_url}"
  [ "${LOG_MASK_URL}" = "mask" ] && log_url="$(mask_url "${update_url}")"
  log Info "开始下载: ${log_url}"

  if which curl >/dev/null; then
    http_code=$(curl -L -s --insecure --http1.1 --compressed --user-agent "${current_ua}" -o "${file}" -w "%{http_code}" "${update_url}")
    curl_exit_code=$?
    if [ ${curl_exit_code} -ne 0 ]; then
      log Error "使用 curl 下载失败 (退出码: ${curl_exit_code})"
      [ -f "${file_bak}" ] && mv "${file_bak}" "${file}"
      return 1
    fi
    if [ "${http_code}" -ne 200 ]; then
      log Error "下载失败: 服务器返回 HTTP 状态码 ${http_code}"
      [ -f "${file_bak}" ] && mv "${file_bak}" "${file}"
      return 1
    fi
  else
    if ! busybox wget --no-check-certificate -q -U "${current_ua}" -O "${file}" "${update_url}"; then
      log Error "使用 wget 下载失败"
      [ -f "${file_bak}" ] && mv "${file_bak}" "${file}"
      return 1
    fi
  fi

  if [ ! -s "${file}" ]; then
    log Error "下载失败: 文件为空"
    [ -f "${file_bak}" ] && mv "${file_bak}" "${file}"
    return 1
  fi

  log Info "下载成功"
  rm -f "${file_bak}" 2>/dev/null
  return 0
}

upcnip() {
  local did_any=false
  if [ "${bypass_cn_ip}" = "true" ] && [ "${bypass_cn_ip_v4}" = "true" ]; then
    if [ -n "${cn_ip_url}" ] && [ -n "${cn_ip_file}" ]; then
      log Info "下载 CN IPv4 列表 → ${cn_ip_file}"
      if upfile "${cn_ip_file}" "${cn_ip_url}"; then
        log Info "CN IPv4 列表更新完成"
        did_any=true
      else
        log Error "CN IPv4 列表更新失败"
      fi
    fi
  fi
  if [ "${bypass_cn_ip}" = "true" ] && [ "${ipv6}" = "true" ] && [ "${bypass_cn_ip_v6}" = "true" ]; then
    if [ -n "${cn_ipv6_url}" ] && [ -n "${cn_ipv6_file}" ]; then
      log Info "下载 CN IPv6 列表 → ${cn_ipv6_file}"
      if upfile "${cn_ipv6_file}" "${cn_ipv6_url}"; then
        log Info "CN IPv6 列表更新完成"
        did_any=true
      else
        log Error "CN IPv6 列表更新失败"
      fi
    fi
  fi
  $did_any && return 0 || return 1
}

restart_box() {
  "${scripts_dir}/box.service" restart
  local pid
  pid=$(busybox pidof "sing-box")
  if [ -n "$pid" ]; then
    log Info "sing-box 重启完成 [$(date +"%F %R")]"
  else
    log Error "重启 sing-box 失败"
    "${scripts_dir}/box.iptables" disable >/dev/null 2>&1
  fi
}

check() {
  if "${bin_path}" check -c "${sing_config}" > "${box_run}/sing-box_report.log" 2>&1; then
    log Info "${sing_config} 检查通过"
  else
    log Info "${sing_config}"
    log Error "$(<"${box_run}/sing-box_report.log")" >&2
  fi
}

reload() {
  local ip_port
  ip_port=$(busybox awk -F'[:,]' '/"external_controller"/ {print $2":"$3}' "${sing_config}" | sed 's/^[ \t]*//;s/"//g')
  local secret
  secret=$(busybox awk -F'"' '/"secret"/ {print $4}' "${sing_config}" | head -n 1)

  curl_command="curl"
  if ! command -v curl >/dev/null; then
    if [ ! -e "${bin_dir}/curl" ]; then
      log Info "curl 未找到，开始下载"
      upcurl || exit 1
    fi
    curl_command="${bin_dir}/curl"
  fi

  check

  local endpoint="http://${ip_port}/configs?force=true"
  if ${curl_command} -X PUT -H "Authorization: Bearer ${secret}" "${endpoint}" -d '{"path": "", "payload": ""}' 2>&1; then
    log Info "sing-box 配置重载成功"
    return 0
  else
    log Error "sing-box 配置重载失败"
    return 1
  fi
}

upcurl() {
  setup_github_api
  local arch
  case $(uname -m) in
    "aarch64") arch="aarch64" ;;
    "armv7l"|"armv8l") arch="armv7" ;;
    "i686") arch="i686" ;;
    "x86_64") arch="amd64" ;;
    *) log Warning "不支持的架构: $(uname -m)" >&2; return 1 ;;
  esac
  mkdir -p "${bin_dir}/backup"
  [ -f "${bin_dir}/curl" ] && cp "${bin_dir}/curl" "${bin_dir}/backup/curl.bak" >/dev/null 2>&1
  local latest_version=$($rev1 "https://api.github.com/repos/stunnel/static-curl/releases" | grep "tag_name" | busybox grep -oE "[0-9.]*" | head -1)
  local download_link="https://github.com/stunnel/static-curl/releases/download/${latest_version}/curl-linux-${arch}-glibc-${latest_version}.tar.xz"
  local temp_archive="${box_dir}/curl.tar.xz"
  local temp_extract_dir="${box_dir}/curl_temp"
  log Info "下载 ${download_link}"
  if ! upfile "${temp_archive}" "${download_link}"; then
    log Error "下载 curl 失败"
    return 1
  fi
  rm -rf "${temp_extract_dir}"
  mkdir -p "${temp_extract_dir}"
  if ! busybox tar -xJf "${temp_archive}" -C "${temp_extract_dir}" >&2; then
    log Error "解压 ${temp_archive} 失败"
    cp "${bin_dir}/backup/curl.bak" "${bin_dir}/curl" >/dev/null 2>&1 && log Info "已恢复 curl"
    rm -f "${temp_archive}"; rm -rf "${temp_extract_dir}"
    return 1
  fi
  local curl_binary=$(find "${temp_extract_dir}" -type f -name "curl")
  if [ -n "${curl_binary}" ]; then
    mv "${curl_binary}" "${bin_dir}/curl"
    log Info "curl 已成功更新到 ${bin_dir}/curl"
  else
    log Error "未找到 curl 二进制文件"
    rm -f "${temp_archive}"; rm -rf "${temp_extract_dir}"
    return 1
  fi
  chown "${box_user_group}" "${box_dir}/bin/curl"
  chmod 0755 "${bin_dir}/curl"
  rm -f "${temp_archive}"; rm -rf "${temp_extract_dir}"
}

upyq() {
  local arch platform
  case $(uname -m) in
    "aarch64") arch="arm64"; platform="android" ;;
    "armv7l"|"armv8l") arch="arm"; platform="android" ;;
    "i686") arch="386"; platform="android" ;;
    "x86_64") arch="amd64"; platform="android" ;;
    *) log Warning "不支持的架构: $(uname -m)" >&2; return 1 ;;
  esac
  local download_link="https://github.com/taamarin/yq/releases/download/prerelease/yq_${platform}_${arch}"
  log Info "下载 ${download_link}"
  upfile "${box_dir}/bin/yq" "${download_link}"
  chown "${box_user_group}" "${box_dir}/bin/yq"
  chmod 0755 "${box_dir}/bin/yq"
}

upgeox() {
  local geoip_file="${box_dir}/sing-box/geoip.db"
  local geoip_url="https://github.com/MetaCubeX/meta-rules-dat/raw/release/geoip-lite.db"
  local geosite_file="${box_dir}/sing-box/geosite.db"
  local geosite_url="https://github.com/MetaCubeX/meta-rules-dat/raw/release/geosite.db"

  if [ "${update_geo}" = "true" ]; then
    log Info "每日更新 GeoX"
    log Info "正在下载 ${geoip_url}"
    upfile "${geoip_file}" "${geoip_url}"
    log Info "正在下载 ${geosite_url}"
    upfile "${geosite_file}" "${geosite_url}"
    find "${box_dir}/sing-box" -maxdepth 1 -type f -name "*.db.bak" -delete
    log Info "更新 GeoX 于 $(date "+%F %R")"
    return 0
  else
    log Warning "update_geo 未启用，跳过 GeoX 更新"
    return 1
  fi
}

upsubs() {
  if [ "${update_subscription}" != "true" ]; then
    log Warning "更新订阅已禁用: update_subscription=\"${update_subscription}\""
    return 1
  fi

  if [ -n "${subscription_url_singbox}" ]; then
    log Info "sing-box 更新订阅 → $(date)"
    if upfile "${sing_config}" "${subscription_url_singbox}" "sing-box"; then
      log Info "${sing_config} 已保存"
      log Info "更新订阅于 $(date +"%F %R")"
      if [ -f "${box_pid}" ]; then
        kill -0 "$(<"${box_pid}" 2>/dev/null)" && \
        "${scripts_dir}/box.service" restart 2>/dev/null
      fi
      return 0
    else
      log Error "更新订阅失败"
      return 1
    fi
  else
    log Warning "sing-box 订阅链接为空"
    return 1
  fi
}

upkernel() {
  setup_github_api
  local arch platform
  case $(uname -m) in
    "aarch64") arch="arm64"; platform="android" ;;
    "armv7l"|"armv8l") arch="armv7"; platform="linux" ;;
    "i686") arch="386"; platform="linux" ;;
    "x86_64") arch="amd64"; platform="linux" ;;
    *) log Warning "不支持的架构: $(uname -m)" >&2; return 1 ;;
  esac

  local api_url="https://api.github.com/repos/SagerNet/sing-box/releases"
  local url_down="https://github.com/SagerNet/sing-box/releases"
  local latest_version

  mkdir -p "${bin_dir}/backup"
  [ -f "${bin_dir}/sing-box" ] && cp "${bin_dir}/sing-box" "${bin_dir}/backup/sing-box.bak" >/dev/null 2>&1

  if [ "${singbox_stable}" = "disable" ]; then
    log Info "下载 sing-box 预发行版"
    latest_version=$($rev1 "${api_url}" | grep "tag_name" | busybox grep -oE "v[0-9].*" | head -1 | cut -d'"' -f1)
  else
    log Info "下载 sing-box 最新稳定版"
    latest_version=$($rev1 "${api_url}/latest" | grep "tag_name" | busybox grep -oE "v[0-9.]*" | head -1)
  fi

  if [ -z "$latest_version" ]; then
    log Error "获取 sing-box 最新版本失败"
    return 1
  fi

  local file_kernel="sing-box-${arch}"
  local download_link="${url_down}/download/${latest_version}/sing-box-${latest_version#v}-${platform}-${arch}.tar.gz"
  log Info "下载 ${download_link}"

  if upfile "${box_dir}/${file_kernel}.tar.gz" "${download_link}"; then
    log Info "正在解压 sing-box 核心..."
    if busybox tar -xf "${box_dir}/${file_kernel}.tar.gz" -C "${bin_dir}" >/dev/null; then
      mv "${bin_dir}/sing-box-${latest_version#v}-${platform}-${arch}/sing-box" "${bin_dir}/sing-box"
      [ -d "${bin_dir}/sing-box-${latest_version#v}-${platform}-${arch}" ] && \
        rm -r "${bin_dir}/sing-box-${latest_version#v}-${platform}-${arch}"
      chown "${box_user_group}" "${bin_dir}/sing-box"
      chmod 0755 "${bin_dir}/sing-box"
      log Info "sing-box 已更新到 ${latest_version}"
      if [ -f "${box_pid}" ]; then
        log Info "检测到正在运行的服务，自动重启..."
        rm -f /data/adb/box/sing-box/cache.db
        restart_box
      else
        log Info "服务未在运行，无需重启"
      fi
    else
      log Error "解压 ${box_dir}/${file_kernel}.tar.gz 失败"
      return 1
    fi
    find "${box_dir}" -maxdepth 1 -type f -name "${file_kernel}.*" -delete
  else
    log Error "下载 sing-box 失败"
    return 1
  fi
}

upxui() {
  local ui_path
  ui_path=$(busybox awk -F '"' '/"external_ui"/ {print $4}' "${sing_config}" | head -n 1)
  local ui_url
  ui_url=$(busybox awk -F '"' '/"external_ui_download_url"/ {print $4; exit}' "${sing_config}" 2>/dev/null)

  [ -z "${ui_path}" ] && ui_path="./dashboard" && log Warning "未找到 external_ui 字段，使用默认路径: ${ui_path}"

  local dashboard_dir
  if [[ "${ui_path}" == ./* ]]; then
    dashboard_dir="${box_dir}/sing-box/${ui_path#./}"
  elif [[ "${ui_path}" == /* ]]; then
    dashboard_dir="${ui_path}"
  else
    dashboard_dir="${box_dir}/sing-box/${ui_path}"
  fi
  log Info "Dashboard 目标目录: ${dashboard_dir}"

  local file_dashboard="${box_dir}/sing-box_dashboard.zip"
  [ -n "${ui_url}" ] && url="${ui_url}" || url="https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip"

  if upfile "${file_dashboard}" "${url}"; then
    mkdir -p "${dashboard_dir}"
    rm -rf "${dashboard_dir}/"*
    local unzip_command="unzip"
    command -v unzip >/dev/null || unzip_command="busybox unzip"
    if ${unzip_command} -oq "${file_dashboard}" -d "${dashboard_dir}" >/dev/null; then
      # 如果解压出 dist/ 子目录，则移出
      if [ -d "${dashboard_dir}/dist" ]; then
        mv "${dashboard_dir}/dist/"* "${dashboard_dir}/"
        rm -rf "${dashboard_dir}/dist"
      fi
      log Info "Dashboard 已更新: ${dashboard_dir}"
    else
      log Error "解压 Dashboard 失败"
    fi
    rm -f "${file_dashboard}"
  else
    log Error "下载 Dashboard 失败"
    return 1
  fi
}

cgroup_memcg() {
  local pid_file="$1"
  local limit="$2"
  if [ -z "${pid_file}" ] || [ ! -f "${pid_file}" ]; then
    log Warning "PID 文件丢失或无效: ${pid_file}"
    return 1
  fi
  local PID; PID=$(<"${pid_file}" 2>/dev/null)
  if [ -z "$PID" ] || ! kill -0 "$PID" >/dev/null; then
    log Warning "PID $PID 无效或未运行"
    return 1
  fi
  [ -z "${limit}" ] && limit="100M"
  if [ -z "${memcg_path}" ]; then
    memcg_path=$(mount | grep cgroup | busybox awk '/memory/{print $3}' | head -1)
    [ -z "${memcg_path}" ] && { log Warning "memcg_path 未找到"; return 1; }
  fi
  local memcg_target="${memcg_path}/box"
  mkdir -p "${memcg_target}" 2>/dev/null || memcg_target="${memcg_path}"
  local limit_bytes
  case "${limit}" in
    *M) limit_bytes=$(( ${limit%M} * 1024 * 1024 )) ;;
    *G) limit_bytes=$(( ${limit%G} * 1024 * 1024 * 1024 )) ;;
    *) limit_bytes="${limit}" ;;
  esac
  echo "${limit_bytes}" > "${memcg_target}/memory.limit_in_bytes" 2>/dev/null || {
    log Warning "设置内存限制失败"
    return 1
  }
  echo "${PID}" > "${memcg_target}/cgroup.procs" 2>/dev/null && \
    log Info "已设置内存限制 ${limit} 到 PID $PID" || {
    log Warning "无法将 PID $PID 分配到 ${memcg_target}"
    return 1
  }
}

cgroup_cpuset() {
  local pid_file="$1"
  local cores="$2"
  if [ -z "${pid_file}" ] || [ ! -f "${pid_file}" ]; then
    log Warning "PID 文件丢失或无效: ${pid_file}"
    return 1
  fi
  local PID; PID=$(<"${pid_file}" 2>/dev/null)
  if [ -z "$PID" ] || ! kill -0 "$PID" >/dev/null; then
    log Warning "PID $PID 无效或未运行"
    return 1
  fi
  [ -z "${cores}" ] && cores="0-$(($(nproc --all 2>/dev/null || echo 4) - 1))"
  if [ -z "${cpuset_path}" ]; then
    cpuset_path=$(mount | grep cgroup | busybox awk '/cpuset/{print $3}' | head -1)
    [ -z "${cpuset_path}" ] && { log Warning "cpuset_path 未找到"; return 1; }
  fi
  local cpuset_target="${cpuset_path}/box"
  mkdir -p "${cpuset_target}" 2>/dev/null || cpuset_target="${cpuset_path}/top-app"
  echo "${cores}" > "${cpuset_target}/cpus" 2>/dev/null && \
  echo "0" > "${cpuset_target}/mems" 2>/dev/null && \
  echo "${PID}" > "${cpuset_target}/cgroup.procs" 2>/dev/null && \
    log Info "已分配 PID $PID 到 ${cpuset_target}，CPU 核心 [${cores}]" || {
    log Warning "无法配置 cpuset"
    return 1
  }
}

cgroup_blkio() {
  local pid_file="$1"
  local weight="$2"
  if [ -z "${pid_file}" ] || [ ! -f "${pid_file}" ]; then
    log Warning "PID 文件丢失或无效: ${pid_file}"
    return 1
  fi
  local PID; PID=$(<"${pid_file}" 2>/dev/null)
  if [ -z "$PID" ] || ! kill -0 "$PID" >/dev/null; then
    log Warning "PID $PID 无效或未运行"
    return 1
  fi
  [ -z "${weight}" ] && weight="500"
  if [ -z "${blkio_path}" ]; then
    blkio_path=$(mount | grep cgroup | busybox awk '/blkio/{print $3}' | head -1)
    [ -z "${blkio_path}" ] && { log Warning "blkio_path 未找到"; return 1; }
  fi
  local blkio_target="${blkio_path}/box"
  mkdir -p "${blkio_target}" 2>/dev/null || blkio_target="${blkio_path}"
  echo "${weight}" > "${blkio_target}/blkio.weight" 2>/dev/null && \
  echo "${PID}" > "${blkio_target}/cgroup.procs" 2>/dev/null && \
    log Info "已设置磁盘 I/O 权重 ${weight} 到 PID $PID" || {
    log Warning "无法配置 blkio"
    return 1
  }
}

webroot() {
  local path_webroot="/data/adb/modules/box_for_root/webroot/index.html"
  touch "${path_webroot}"
  cat > "${path_webroot}" <<'EOF'
<!DOCTYPE html>
<html>
<head>
<meta http-equiv="refresh" content="0; url=https://board.zash.run.place/#/proxies">
<script>window.location.href="https://board.zash.run.place/#/proxies";</script>
</head>
<body>正在跳转到 Zashboard...</body>
</html>
EOF
  log Info "已生成 WebUI 页面: ${path_webroot}"
}

bond0() {
  sysctl -w net.ipv4.tcp_low_latency=0 >/dev/null 2>&1
  for dev in /sys/class/net/wlan*; do ip link set dev $(basename $dev) txqueuelen 3000; done
  for txqueuelen in /sys/class/net/rmnet_data*; do ip link set dev $(basename $txqueuelen) txqueuelen 1000; done
  for mtu in /sys/class/net/rmnet_data*; do ip link set dev $(basename $mtu) mtu 1500; done
  log Info "网络优化 bond0 已应用"
}

bond1() {
  sysctl -w net.ipv4.tcp_low_latency=1 >/dev/null 2>&1
  for dev in /sys/class/net/wlan*; do ip link set dev $(basename $dev) txqueuelen 4000; done
  for txqueuelen in /sys/class/net/rmnet_data*; do ip link set dev $(basename $txqueuelen) txqueuelen 2000; done
  for mtu in /sys/class/net/rmnet_data*; do ip link set dev $(basename $mtu) mtu 9000; done
  log Info "网络优化 bond1 已应用"
}

case "$1" in
  check)
    check
    ;;
  memcg|cpuset|blkio)
    case "$1" in
      memcg)  memcg_path="";  cgroup_memcg "${box_pid}" ${memcg_limit} ;;
      cpuset) cpuset_path=""; cgroup_cpuset "${box_pid}" ${allow_cpu} ;;
      blkio)  blkio_path="";  cgroup_blkio "${box_pid}" "${weight}" ;;
    esac
    ;;
  bond0|bond1)
    $1
    ;;
  geosub)
    upsubs || exit 1
    upgeox
    if [ -f "${box_pid}" ]; then
      kill -0 "$(<"${box_pid}" 2>/dev/null)" && reload
    fi
    ;;
  geox)
    upgeox
    if [ -f "${box_pid}" ]; then
      kill -0 "$(<"${box_pid}" 2>/dev/null)" && reload
    fi
    ;;
  subs)
    upsubs || exit 1
    if [ -f "${box_pid}" ]; then
      kill -0 "$(<"${box_pid}" 2>/dev/null)" && reload
    fi
    ;;
  upkernel)
    upkernel
    ;;
  upgeox_all)
    upgeox
    ;;
  upxui)
    upxui
    ;;
  upcnip)
    upcnip
    ;;
  upyq|upcurl)
    $1
    ;;
  reload)
    reload
    ;;
  webroot)
    webroot
    ;;
  all)
    upyq
    upcurl
    upgeox
    upkernel
    upsubs
    upxui
    ;;
  "")
    log Info "未指定命令，执行默认操作: 下载 yq 和 sing-box 内核"
    setup_github_api
    upyq
    upkernel
    ;;
  *)
    log Error "$0 '$1' 未找到"
    log Info "用法: $0 {check|memcg|cpuset|blkio|geosub|geox|subs|upkernel|upgeox_all|upxui|upyq|upcurl|upcnip|reload|webroot|bond0|bond1|all}"
    log Info "不带参数运行时，默认下载 yq 和 sing-box 内核"
    ;;
esac

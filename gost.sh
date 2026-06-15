#! /bin/bash
Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Green_background_prefix="\033[42;37m" && Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
shell_version="1.1.13"
ct_new_ver="2.11.2" # 2.x 不再跟随官方更新
gost_conf_path="/etc/gost/config.json"
raw_conf_path="/etc/gost/rawconf"
install_tmp_dir=""
peer_tmp_file=""
release=""
service_manager=""
share_code_max_length=8192

cleanup_temp() {
  if [[ -n "${install_tmp_dir}" && -d "${install_tmp_dir}" ]]; then
    rm -rf "${install_tmp_dir}"
    install_tmp_dir=""
  fi
  if [[ -n "${peer_tmp_file}" && -f "${peer_tmp_file}" ]]; then
    rm -f "${peer_tmp_file}"
    peer_tmp_file=""
  fi
}

handle_interrupt() {
  echo
  echo -e "${Error} 操作已取消，临时文件已清理。"
  cleanup_temp
  exit 130
}

trap cleanup_temp EXIT
trap handle_interrupt INT TERM

is_gost_installed() {
  command -v gost >/dev/null 2>&1 || [[ -f /usr/bin/gost || -f /usr/lib/systemd/system/gost.service || -f /etc/init.d/gost || -d /etc/gost ]]
}

ensure_gost_dir() {
  mkdir -p /etc/gost
}

ensure_raw_conf_file() {
  ensure_gost_dir
  touch "$raw_conf_path"
}

get_service_unit_path() {
  if [[ "${service_manager}" == "openrc" ]]; then
    printf '%s' "/etc/init.d/gost"
  else
    printf '%s' "/usr/lib/systemd/system/gost.service"
  fi
}

write_openrc_service() {
  local target_path="$1"
  cat >"${target_path}" <<'EOF'
#!/sbin/openrc-run

name="gost"
description="gost proxy service"
command="/usr/bin/gost"
command_args="-C /etc/gost/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
supervisor="supervise-daemon"
retry="TERM/30/KILL/5"

depend() {
  need net
  after firewall
}
EOF
}

reload_service_manager() {
  if [[ "${service_manager}" == "openrc" ]]; then
    return 0
  fi
  systemctl daemon-reload
}

enable_gost_service() {
  if [[ "${service_manager}" == "openrc" ]]; then
    rc-update add gost default >/dev/null 2>&1
  else
    systemctl enable gost >/dev/null 2>&1
  fi
}

disable_gost_service() {
  if [[ "${service_manager}" == "openrc" ]]; then
    rc-update del gost default >/dev/null 2>&1
  else
    systemctl disable gost >/dev/null 2>&1
  fi
}

service_action() {
  local action="$1"
  if [[ "${service_manager}" == "openrc" ]]; then
    rc-service gost "${action}"
  else
    systemctl "${action}" gost
  fi
}

get_restart_command() {
  if [[ "${service_manager}" == "openrc" ]]; then
    printf '%s' "rc-service gost restart"
  else
    printf '%s' "systemctl restart gost"
  fi
}

get_cron_file() {
  if [[ "${release}" == "alpine" ]]; then
    printf '%s' "/etc/crontabs/root"
  else
    printf '%s' "/etc/crontab"
  fi
}

get_tmp_base_dir() {
  if [[ -n "${TMPDIR}" && -d "${TMPDIR}" ]]; then
    printf '%s' "${TMPDIR}"
  elif [[ -d /tmp ]]; then
    printf '%s' "/tmp"
  else
    printf '%s' "."
  fi
}

make_temp_dir() {
  local prefix="$1"
  local tmp_base=""
  local template=""
  tmp_base="$(get_tmp_base_dir)"
  template="${prefix}.XXXXXX"

  mktemp -d "${tmp_base%/}/${template}" 2>/dev/null && return 0
  mktemp -d -p "${tmp_base}" "${template}" 2>/dev/null && return 0
  mktemp -d -t "${prefix}.XXXXXX" 2>/dev/null && return 0
  return 1
}

make_temp_file() {
  local prefix="$1"
  local suffix="$2"
  local tmp_base=""
  local template=""
  tmp_base="$(get_tmp_base_dir)"
  template="${prefix}.XXXXXX${suffix}"

  mktemp "${tmp_base%/}/${template}" 2>/dev/null && return 0
  mktemp -p "${tmp_base}" "${template}" 2>/dev/null && return 0
  mktemp -t "${prefix}.XXXXXX${suffix}" 2>/dev/null && return 0
  return 1
}

append_cron_line() {
  local cron_line="$1"
  local cron_file=""
  cron_file=$(get_cron_file)
  echo "${cron_line}" >>"${cron_file}"
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535))
}

validate_menu_number() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

validate_no_space_or_delimiter() {
  [[ -n "$1" && "$1" != *"#"* && "$1" != *[[:space:]]* ]]
}

is_ipv4() {
  local ip="$1"
  local IFS=.
  local parts=()
  read -r -a parts <<<"$ip"
  [[ ${#parts[@]} -eq 4 ]] || return 1
  local part
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9]+$ ]] || return 1
    ((10#$part >= 0 && 10#$part <= 255)) || return 1
  done
}

is_ipv6() {
  local ip="$1"
  [[ "$ip" == *:* ]] || return 1
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY' "$ip"
import ipaddress
import sys
try:
    ipaddress.IPv6Address(sys.argv[1])
except Exception:
    raise SystemExit(1)
raise SystemExit(0)
PY
    return $?
  fi
  [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]]
}

is_hostname() {
  local host="$1"
  [[ "$host" =~ [A-Za-z-] ]] || return 1
  [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  [[ "$host" != .* && "$host" != *. && "$host" != *..* ]] || return 1
}

normalize_host() {
  local host="$1"
  if [[ "$host" =~ ^\[[^][]+\]$ ]]; then
    printf '%s' "$host"
    return 0
  fi
  if is_ipv6 "$host"; then
    printf '[%s]' "$host"
    return 0
  fi
  printf '%s' "$host"
}

validate_host() {
  local host="$1"
  if [[ "$host" =~ ^\[(.*)\]$ ]]; then
    is_ipv6 "${BASH_REMATCH[1]}"
    return $?
  fi
  is_ipv4 "$host" || is_ipv6 "$host" || is_hostname "$host"
}

validate_host_header() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]]
}

validate_filename_token() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

validate_bundle_entry_name() {
  local entry="$1"
  entry="${entry#./}"
  case "${entry}" in
  "" | "." | "./")
    return 0
    ;;
  rawconf | config.json | manifest.txt)
    return 0
    ;;
  peer_files | peer_files/)
    return 0
    ;;
  peer_files/*.txt)
    validate_filename_token "$(basename "${entry}" .txt)"
    return $?
    ;;
  *)
    return 1
    ;;
  esac
}

validate_bundle_archive() {
  local archive_file="$1"
  local entry_name=""
  local verbose_line=""
  if ! tar -tzf "${archive_file}" >/dev/null 2>&1; then
    echo -e "${Error} 归档文件无法读取或格式错误。"
    return 1
  fi
  while IFS= read -r entry_name; do
    [[ -n "${entry_name}" ]] || continue
    if [[ "${entry_name}" == /* || "${entry_name}" == *"../"* || "${entry_name}" == ../* || "${entry_name}" == *"..\\"* ]]; then
      echo -e "${Error} 归档包含非法路径：${entry_name}"
      return 1
    fi
    if ! validate_bundle_entry_name "${entry_name}"; then
      echo -e "${Error} 归档包含不受支持的文件：${entry_name}"
      return 1
    fi
  done < <(tar -tzf "${archive_file}")

  while IFS= read -r verbose_line; do
    [[ -n "${verbose_line}" ]] || continue
    case "${verbose_line:0:1}" in
    l | h)
      echo -e "${Error} 归档中不允许符号链接或硬链接。"
      return 1
      ;;
    esac
  done < <(tar -tvzf "${archive_file}")
}

safe_extract_bundle() {
  local archive_file="$1"
  local target_dir="$2"
  if ! validate_bundle_archive "${archive_file}"; then
    return 1
  fi
  tar -xzf "${archive_file}" -C "${target_dir}"
}

validate_host_port_pair() {
  local host_port="$1"
  local host_part=""
  local port_part=""
  if [[ "${host_port}" =~ ^(\[[^][]+\]):([0-9]+)$ ]]; then
    host_part="${BASH_REMATCH[1]}"
    port_part="${BASH_REMATCH[2]}"
  elif [[ "${host_port}" =~ ^([^:]+):([0-9]+)$ ]]; then
    host_part="${BASH_REMATCH[1]}"
    port_part="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  validate_host "${host_part}" && validate_port "${port_part}"
}

validate_rawconf_line() {
  local line="$1"
  local head=""
  local field_target=""
  local field_value=""
  local rule_type=""
  local source_value=""

  [[ -n "${line}" ]] || return 1
  [[ "${line}" != *'"'* && "${line}" != *'\'* ]] || return 1
  [[ "${line}" == */*#*#* ]] || return 1

  head="${line%%#*}"
  field_target="${line#*#}"
  field_value="${field_target#*#}"
  field_target="${field_target%%#*}"
  rule_type="${head%%/*}"
  source_value="${head#*/}"

  case "${rule_type}" in
  nonencrypt | encrypttls | encryptws | encryptwss | encryptquic | encryptkcp | decrypttls | decryptws | decryptwss | decryptquic | decryptkcp)
    validate_port "${source_value}" || return 1
    ;;
  peerno | peertls | peerws | peerwss | peerquic | peerkcp | cdnno | cdnws | cdnwss)
    validate_port "${source_value}" || return 1
    ;;
  ss | socks | http)
    validate_no_space_or_delimiter "${source_value}" || return 1
    ;;
  *)
    return 1
    ;;
  esac

  case "${rule_type}" in
  nonencrypt | encrypttls | encryptws | encryptwss | encryptquic | encryptkcp | decrypttls | decryptws | decryptwss | decryptquic | decryptkcp)
    validate_host "${field_target}" || validate_host_header "${field_target}" || return 1
    [[ "${field_value}" == *"?secure=true" ]] && field_value="${field_value%\?secure=true}"
    validate_port "${field_value}" || return 1
    ;;
  ss)
    validate_no_space_or_delimiter "${source_value}" || return 1
    [[ "${field_target}" == "aes-256-gcm" || "${field_target}" == "aes-256-cfb" || "${field_target}" == "chacha20-ietf-poly1305" || "${field_target}" == "chacha20" || "${field_target}" == "rc4-md5" || "${field_target}" == "AEAD_CHACHA20_POLY1305" ]] || return 1
    validate_port "${field_value}" || return 1
    ;;
  socks | http)
    validate_no_space_or_delimiter "${source_value}" || return 1
    validate_no_space_or_delimiter "${field_target}" || return 1
    validate_port "${field_value}" || return 1
    ;;
  peerno | peertls | peerws | peerwss | peerquic | peerkcp)
    validate_filename_token "${field_target}" || return 1
    [[ "${field_value}" == "round" || "${field_value}" == "random" || "${field_value}" == "fifo" ]] || return 1
    ;;
  cdnno | cdnws | cdnwss)
    validate_host_port_pair "${field_target}" || return 1
    validate_host_header "${field_value}" || return 1
    ;;
  esac
}

validate_rawconf_file() {
  local source_rawconf="$1"
  local line=""
  [[ -s "${source_rawconf}" ]] || return 1
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    if ! validate_rawconf_line "${line}"; then
      echo -e "${Error} 导入规则存在非法内容：${line}"
      return 1
    fi
  done <"${source_rawconf}"
}

normalize_input() {
  local input="$1"
  local output=""
  local char=""
  while IFS= read -r -n1 char; do
    case "$char" in
    $'\b' | $'\x7f')
      output="${output%?}"
      ;;
    $'\r' | $'\n')
      ;;
    [[:cntrl:]])
      ;;
    *)
      output+="$char"
      ;;
    esac
  done <<<"$input"
  printf '%s' "$output"
}

normalize_share_code() {
  local input="$1"
  printf '%s' "${input}" | tr -d '[:space:]'
}

build_migration_command() {
  local share_code="$1"
  local import_mode="${2:-overwrite}"
  printf "%s" "bash <(curl -fsSL https://raw.githubusercontent.com/YeJianbo/Multi-EasyGost/v2/gost.sh) --import-share-code '${share_code}' --import-mode ${import_mode}"
}

read_prompt_line() {
  local prompt="$1"
  local answer=""

  if [[ -t 0 && -t 1 ]]; then
    if read -e -r -p "$prompt" answer; then
      REPLY="${answer}"
      return 0
    fi
  fi

  read -r -p "$prompt" answer
  REPLY="${answer}"
}

validate_share_code_length() {
  local share_code="$1"
  local code_length=0
  code_length=${#share_code}
  if ((code_length > share_code_max_length)); then
    echo -e "${Error} 分享码长度为 ${code_length}，超过上限 ${share_code_max_length}。"
    echo -e "${Info} 当前分享码更适合单条或少量规则；规则较多时建议拆分为多次分享导入。"
    return 1
  fi
}

ask_yes_no() {
  local prompt="$1"
  local default_value="$2"
  local answer
  while true; do
    read_prompt_line "$prompt"
    answer=$(normalize_input "$REPLY")
    [[ -z "${answer}" ]] && answer="${default_value}"
    case "${answer}" in
    [Yy] | [Yy][Ee][Ss])
      return 0
      ;;
    [Nn] | [Nn][Oo])
      return 1
      ;;
    *)
      echo "请输入 y 或 n"
      ;;
    esac
  done
}

prompt_choice() {
  local prompt="$1"
  shift
  local answer
  while true; do
    read_prompt_line "$prompt"
    answer=$(normalize_input "$REPLY")
    for option in "$@"; do
      if [[ "${answer}" == "${option}" ]]; then
        REPLY="${answer}"
        return 0
      fi
    done
    echo "请输入正确选项: $*"
  done
}

prompt_nonempty() {
  local prompt="$1"
  local validator="$2"
  local error_message="$3"
  local answer
  while true; do
    read_prompt_line "$prompt"
    answer=$(normalize_input "$REPLY")
    if [[ -n "${answer}" ]] && { [[ -z "${validator}" ]] || "${validator}" "${answer}"; }; then
      REPLY="${answer}"
      return 0
    fi
    echo "${error_message}"
  done
}

pause_before_menu() {
  echo
  read_prompt_line "按回车返回主菜单..."
}

download_file() {
  local url="$1"
  local output="$2"
  if command -v wget >/dev/null 2>&1; then
    wget --no-check-certificate -q -O "${output}" "${url}"
  elif command -v curl >/dev/null 2>&1; then
    curl -LkfsS "${url}" -o "${output}"
  else
    return 1
  fi
}

probe_url() {
  local url="$1"
  local duration=""
  local start_ts=""
  local end_ts=""
  if command -v curl >/dev/null 2>&1; then
    duration=$(curl -Lk -o /dev/null -s -w '%{time_total}' --connect-timeout 5 --max-time 8 "${url}" 2>/dev/null)
    if [[ -n "${duration}" && "${duration}" != "0.000000" ]]; then
      printf '%s\n' "${duration}"
      return 0
    fi
  fi
  if command -v wget >/dev/null 2>&1; then
    start_ts=$(date +%s%3N 2>/dev/null)
    if wget --no-check-certificate -q --spider -T 8 "${url}" 2>/dev/null; then
      end_ts=$(date +%s%3N 2>/dev/null)
      if [[ -n "${start_ts}" && -n "${end_ts}" ]]; then
        awk -v start="${start_ts}" -v end="${end_ts}" 'BEGIN { printf "%.3f\n", (end-start)/1000 }'
        return 0
      fi
      printf '1.000\n'
      return 0
    fi
  fi
  return 1
}

choose_download_source() {
  local global_probe_url="https://raw.githubusercontent.com/YeJianbo/Multi-EasyGost/v2/gost.service"
  local cn_probe_url="https://gotunnel.oss-cn-shenzhen.aliyuncs.com/gost.service"
  local global_time=""
  local cn_time=""

  global_time=$(probe_url "${global_probe_url}") || global_time=""
  cn_time=$(probe_url "${cn_probe_url}") || cn_time=""

  if [[ -n "${global_time}" && -n "${cn_time}" ]]; then
    if awk -v global="${global_time}" -v cn="${cn_time}" 'BEGIN { exit !(cn < global) }'; then
      REPLY="cn"
    else
      REPLY="global"
    fi
  elif [[ -n "${global_time}" ]]; then
    REPLY="global"
  elif [[ -n "${cn_time}" ]]; then
    REPLY="cn"
  else
    REPLY="global"
  fi
}

rebuild_config() {
  ensure_raw_conf_file
  rm -f "$gost_conf_path"
  confstart
  writeconf
  conflast
}

apply_runtime_config() {
  check_root
  check_sys
  if ! is_gost_installed; then
    echo -e "${Error} gost 尚未安装，请先安装。"
    return 1
  fi
  rebuild_config
  if service_action restart; then
    return 0
  fi
  echo -e "${Error} gost 重启失败，请检查配置内容。"
  return 1
}

list_peer_files_from_rawconf() {
  local source_rawconf="$1"
  local line=""
  local rule_type=""
  local target_name=""
  [[ -f "${source_rawconf}" ]] || return 0
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    rule_type="${line%%/*}"
    if [[ "${rule_type}" == peer* ]]; then
      target_name="${line#*#}"
      target_name="${target_name%%#*}"
      if validate_filename_token "${target_name}"; then
        echo "/root/${target_name}.txt"
      fi
    fi
  done <"${source_rawconf}"
}

prepare_rule_bundle() {
  local source_rawconf="$1"
  local target_dir="$2"
  local peer_file=""
  local missing_peer=0
  local selected_rule=""

  mkdir -p "${target_dir}/peer_files"
  cp "${source_rawconf}" "${target_dir}/rawconf"
  if [[ -f "$gost_conf_path" ]]; then
    cp "$gost_conf_path" "${target_dir}/config.json"
  fi
  cat >"${target_dir}/manifest.txt" <<EOF
shell_version=${shell_version}
export_time=$(date '+%Y-%m-%d %H:%M:%S %z')
rawconf_path=${raw_conf_path}
EOF

  while IFS= read -r peer_file; do
    [[ -n "${peer_file}" ]] || continue
    if [[ ! -f "${peer_file}" ]]; then
      echo -e "${Error} 规则引用的落地列表文件不存在：${peer_file}"
      missing_peer=1
      continue
    fi
    cp "${peer_file}" "${target_dir}/peer_files/"
  done < <(list_peer_files_from_rawconf "${source_rawconf}" | sort -u)

  [[ ${missing_peer} -eq 0 ]]
}

build_selected_rawconf() {
  local output_rawconf="$1"
  local selection_mode="$2"
  local selected_index=""
  local selected_expr=""
  local selected_part=""
  local range_start=0
  local range_end=0
  local selected_line=0
  local total_rules=0

  ensure_raw_conf_file
  if [[ ! -s "$raw_conf_path" ]]; then
    echo -e "${Error} 当前没有可导出的规则。"
    return 1
  fi

  show_all_conf
  total_rules=$(awk 'END{print NR}' "$raw_conf_path")
  : >"${output_rawconf}"

  if [[ "${selection_mode}" == "single" ]]; then
    while true; do
      prompt_nonempty "请输入要导出的规则编号：" validate_menu_number "请输入正确数字"
      selected_index="$REPLY"
      if ((10#$selected_index >= 1 && 10#$selected_index <= total_rules)); then
        break
      fi
      echo "编号超出范围，请输入 1-${total_rules}"
    done
    sed -n "${selected_index}p" "$raw_conf_path" >"${output_rawconf}"
    [[ -s "${output_rawconf}" ]]
    return $?
  fi

  while true; do
    read_prompt_line "请输入要导出的规则编号，支持 1,3,5-7；直接回车导出全部: "
    selected_expr=$(normalize_input "${REPLY}")
    selected_expr="${selected_expr// /}"
    if [[ -z "${selected_expr}" ]]; then
      cp "$raw_conf_path" "${output_rawconf}"
      break
    fi
    if [[ ! "${selected_expr}" =~ ^[0-9,-]+$ ]]; then
      echo "格式不正确，请使用 1,3,5-7 这种形式。"
      continue
    fi

    : >"${output_rawconf}"
    declare -A selected_seen=()
    local valid_selection=1
    IFS=',' read -r -a selected_parts <<<"${selected_expr}"
    for selected_part in "${selected_parts[@]}"; do
      [[ -n "${selected_part}" ]] || { valid_selection=0; break; }
      if [[ "${selected_part}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        range_start=$((10#${BASH_REMATCH[1]}))
        range_end=$((10#${BASH_REMATCH[2]}))
        if ((range_start < 1 || range_end < 1 || range_start > range_end || range_end > total_rules)); then
          valid_selection=0
          break
        fi
        for ((selected_line = range_start; selected_line <= range_end; selected_line++)); do
          if [[ -z "${selected_seen[$selected_line]+x}" ]]; then
            sed -n "${selected_line}p" "$raw_conf_path" >>"${output_rawconf}"
            selected_seen[$selected_line]=1
          fi
        done
      elif [[ "${selected_part}" =~ ^[0-9]+$ ]]; then
        selected_line=$((10#${selected_part}))
        if ((selected_line < 1 || selected_line > total_rules)); then
          valid_selection=0
          break
        fi
        if [[ -z "${selected_seen[$selected_line]+x}" ]]; then
          sed -n "${selected_line}p" "$raw_conf_path" >>"${output_rawconf}"
          selected_seen[$selected_line]=1
        fi
      else
        valid_selection=0
        break
      fi
    done
    unset selected_seen

    if ((valid_selection == 1)) && [[ -s "${output_rawconf}" ]]; then
      break
    fi
    echo "编号范围无效，请输入 1-${total_rules} 范围内的编号，例如 1,3,5-7。"
  done

  [[ -s "${output_rawconf}" ]]
}

write_bundle_archive() {
  local source_dir="$1"
  local output_file="$2"
  tar -czf "${output_file}" -C "${source_dir}" .
}

apply_import_bundle() {
  local imported_rawconf="$1"
  local unpack_dir="$2"
  local import_mode="$3"
  local backup_dir=""
  local peer_file=""
  local basename_peer=""
  local peer_rel_path=""
  local merged_rawconf=""
  local missing_peer_list=""

  backup_dir=$(make_temp_dir "gost-import-backup") || {
    echo -e "${Error} 无法创建备份目录。"
    return 1
  }

  while IFS= read -r peer_file; do
    [[ -n "${peer_file}" ]] || continue
    basename_peer="$(basename "${peer_file}")"
    peer_rel_path="${unpack_dir}/peer_files/${basename_peer}"
    if [[ ! -f "${peer_rel_path}" ]]; then
      rm -rf "${backup_dir}"
      echo -e "${Error} 导入包缺少依赖的落地列表文件：${basename_peer}"
      return 1
    fi
  done < <(list_peer_files_from_rawconf "${imported_rawconf}" | sort -u)

  mkdir -p "${backup_dir}/peer_files"
  if [[ -f "$raw_conf_path" ]]; then
    cp "$raw_conf_path" "${backup_dir}/rawconf"
  fi
  while IFS= read -r peer_file; do
    [[ -n "${peer_file}" ]] || continue
    basename_peer="$(basename "${peer_file}")"
    if [[ -f "${peer_file}" ]]; then
      cp "${peer_file}" "${backup_dir}/peer_files/${basename_peer}"
    else
      echo "${peer_file}" >>"${backup_dir}/missing_peer_files.txt"
    fi
  done < <(list_peer_files_from_rawconf "$raw_conf_path" | sort -u)

  if [[ "${import_mode}" == "append" && -s "$raw_conf_path" ]]; then
    merged_rawconf=$(make_temp_file "gost-rawconf-merged" "") || {
      rm -rf "${backup_dir}"
      echo -e "${Error} 无法创建合并配置临时文件。"
      return 1
    }
    cat "$raw_conf_path" >"${merged_rawconf}"
    if [[ -s "${merged_rawconf}" && -s "${imported_rawconf}" ]]; then
      printf '\n' >>"${merged_rawconf}"
    fi
    cat "${imported_rawconf}" >>"${merged_rawconf}"
    cp "${merged_rawconf}" "$raw_conf_path"
    rm -f "${merged_rawconf}"
  else
    cp "${imported_rawconf}" "$raw_conf_path"
  fi

  while IFS= read -r peer_file; do
    [[ -n "${peer_file}" ]] || continue
    basename_peer="$(basename "${peer_file}")"
    cp "${unpack_dir}/peer_files/${basename_peer}" "${peer_file}"
  done < <(list_peer_files_from_rawconf "${imported_rawconf}" | sort -u)

  if apply_runtime_config; then
    echo -e "${Info} 规则导入成功，当前配置如下"
    echo -e "--------------------------------------------------------"
    show_all_conf
    rm -rf "${backup_dir}"
    return 0
  fi

  echo -e "${Error} 导入后的规则未能成功生效，正在回滚。"
  if [[ -f "${backup_dir}/rawconf" ]]; then
    cp "${backup_dir}/rawconf" "$raw_conf_path"
  else
    : >"$raw_conf_path"
  fi
  while IFS= read -r peer_file; do
    [[ -n "${peer_file}" ]] || continue
    basename_peer="$(basename "${peer_file}")"
    if [[ -f "${backup_dir}/peer_files/${basename_peer}" ]]; then
      cp "${backup_dir}/peer_files/${basename_peer}" "${peer_file}"
    fi
  done < <(list_peer_files_from_rawconf "$raw_conf_path" | sort -u)
  missing_peer_list="${backup_dir}/missing_peer_files.txt"
  if [[ -f "${missing_peer_list}" ]]; then
    while IFS= read -r peer_file; do
      [[ -n "${peer_file}" ]] || continue
      rm -f "${peer_file}"
    done <"${missing_peer_list}"
  fi
  apply_runtime_config >/dev/null 2>&1
  rm -rf "${backup_dir}"
  return 1
}

export_rules() {
  local export_dir=""
  local export_file=""
  local export_tmp_dir=""

  check_root
  ensure_raw_conf_file
  if [[ ! -s "$raw_conf_path" ]]; then
    echo -e "${Error} 当前没有可导出的规则。"
    return 1
  fi

  export_tmp_dir=$(make_temp_dir "gost-export") || {
    echo -e "${Error} 无法创建导出临时目录。"
    return 1
  }
  if ! prepare_rule_bundle "$raw_conf_path" "${export_tmp_dir}"; then
    rm -rf "${export_tmp_dir}"
    return 1
  fi

  export_dir="/root"
  export_file="${export_dir}/gost-rules-$(date +%Y%m%d-%H%M%S).tar.gz"
  if write_bundle_archive "${export_tmp_dir}" "${export_file}"; then
    echo -e "${Info} 规则已导出到：${export_file}"
  else
    echo -e "${Error} 规则导出失败。"
    rm -rf "${export_tmp_dir}"
    return 1
  fi
  rm -rf "${export_tmp_dir}"
}

import_rules() {
  local import_path=""
  local unpack_dir=""
  local imported_rawconf=""

  check_root
  if ! is_gost_installed; then
    echo -e "${Error} gost 尚未安装，请先安装。"
    return 1
  fi

  prompt_nonempty "请输入导入文件路径: " "" "导入文件路径不能为空"
  import_path="$REPLY"
  if [[ "${import_path}" != /* ]]; then
    import_path="$(pwd)/${import_path}"
  fi
  if [[ ! -f "${import_path}" ]]; then
    echo -e "${Error} 导入文件不存在：${import_path}"
    return 1
  fi

  unpack_dir=$(make_temp_dir "gost-import") || {
    echo -e "${Error} 无法创建导入临时目录。"
    return 1
  }

  if ! safe_extract_bundle "${import_path}" "${unpack_dir}"; then
    rm -rf "${unpack_dir}"
    echo -e "${Error} 导入包解压失败。"
    return 1
  fi

  imported_rawconf="${unpack_dir}/rawconf"
  if [[ ! -s "${imported_rawconf}" ]]; then
    rm -rf "${unpack_dir}"
    echo -e "${Error} 导入包缺少 rawconf 或规则为空。"
    return 1
  fi
  if ! validate_rawconf_file "${imported_rawconf}"; then
    rm -rf "${unpack_dir}"
    return 1
  fi
  if ! confirm_import_preview "${imported_rawconf}" "overwrite"; then
    rm -rf "${unpack_dir}"
    return 0
  fi

  apply_import_bundle "${imported_rawconf}" "${unpack_dir}" "overwrite"
  local import_status=$?
  rm -rf "${unpack_dir}"
  return ${import_status}
}

export_share_code() {
  local export_mode=""
  local export_tmp_dir=""
  local share_rawconf=""
  local share_archive=""
  local share_code=""
  local answer=""

  check_root
  ensure_raw_conf_file
  if [[ ! -s "$raw_conf_path" ]]; then
    echo -e "${Error} 当前没有可导出的规则。"
    return 1
  fi

  echo -e "分享码导出类型:"
  echo -e "[1] 导出单条规则分享码"
  echo -e "[2] 导出多条规则分享码"
  echo -e "[3] 导出全部规则分享码"
  while true; do
    read_prompt_line "请选择（默认 3）: "
    answer=$(normalize_input "$REPLY")
    [[ -z "${answer}" ]] && answer="3"
    case "${answer}" in
    1 | 2 | 3)
      export_mode="${answer}"
      break
      ;;
    *)
      echo "请输入正确选项: 1 2 3"
      ;;
    esac
  done

  export_tmp_dir=$(make_temp_dir "gost-share-export") || {
    echo -e "${Error} 无法创建分享码临时目录。"
    return 1
  }

  if [[ "${export_mode}" == "1" ]]; then
    share_rawconf="${export_tmp_dir}/selected.rawconf"
    if ! build_selected_rawconf "${share_rawconf}" "single"; then
      rm -rf "${export_tmp_dir}"
      return 1
    fi
  elif [[ "${export_mode}" == "2" ]]; then
    share_rawconf="${export_tmp_dir}/selected.rawconf"
    if ! build_selected_rawconf "${share_rawconf}" "multi"; then
      rm -rf "${export_tmp_dir}"
      return 1
    fi
  else
    share_rawconf="$raw_conf_path"
  fi

  if ! prepare_rule_bundle "${share_rawconf}" "${export_tmp_dir}/bundle"; then
    rm -rf "${export_tmp_dir}"
    return 1
  fi

  share_archive="${export_tmp_dir}/rules.tar.gz"
  if ! write_bundle_archive "${export_tmp_dir}/bundle" "${share_archive}"; then
    echo -e "${Error} 分享码生成失败。"
    rm -rf "${export_tmp_dir}"
    return 1
  fi

  share_code="MEG1:$(base64 -w0 "${share_archive}")"
  if ! validate_share_code_length "${share_code}"; then
    rm -rf "${export_tmp_dir}"
    return 1
  fi
  echo -e "${Info} 分享码如下，复制整串即可："
  echo "${share_code}"
  echo
  echo -e "${Info} 新机器一键迁移命令如下："
  build_migration_command "${share_code}" "overwrite"
  rm -rf "${export_tmp_dir}"
}

import_share_code_value() {
  local share_code=""
  local payload=""
  local unpack_dir=""
  local archive_file=""
  local imported_rawconf=""
  local import_mode=""

  share_code=$(normalize_share_code "$1")
  import_mode="${2:-overwrite}"
  if [[ "${share_code}" != MEG1:* ]]; then
    echo -e "${Error} 分享码格式不正确。"
    return 1
  fi
  if ! validate_share_code_length "${share_code}"; then
    return 1
  fi
  payload="${share_code#MEG1:}"
  if [[ "${import_mode}" != "append" && "${import_mode}" != "overwrite" ]]; then
    echo -e "${Error} 导入模式不正确，仅支持 append 或 overwrite。"
    return 1
  fi

  unpack_dir=$(make_temp_dir "gost-share-import") || {
    echo -e "${Error} 无法创建分享码导入临时目录。"
    return 1
  }
  archive_file="${unpack_dir}/rules.tar.gz"
  if ! printf '%s' "${payload}" | base64 -d >"${archive_file}" 2>/dev/null; then
    rm -rf "${unpack_dir}"
    echo -e "${Error} 分享码解码失败。"
    return 1
  fi
  if ! safe_extract_bundle "${archive_file}" "${unpack_dir}"; then
    rm -rf "${unpack_dir}"
    echo -e "${Error} 分享码内容解压失败。"
    return 1
  fi

  imported_rawconf="${unpack_dir}/rawconf"
  if [[ ! -s "${imported_rawconf}" ]]; then
    rm -rf "${unpack_dir}"
    echo -e "${Error} 分享码缺少有效规则。"
    return 1
  fi
  if ! validate_rawconf_file "${imported_rawconf}"; then
    rm -rf "${unpack_dir}"
    return 1
  fi
  if ! confirm_import_preview "${imported_rawconf}" "${import_mode}"; then
    rm -rf "${unpack_dir}"
    return 0
  fi

  apply_import_bundle "${imported_rawconf}" "${unpack_dir}" "${import_mode}"
  local import_status=$?
  rm -rf "${unpack_dir}"
  return ${import_status}
}

import_share_code() {
  local share_code=""
  local import_mode=""

  check_root
  if ! is_gost_installed; then
    echo -e "${Error} gost 尚未安装，请先安装。"
    return 1
  fi

  prompt_nonempty "请粘贴分享码: " "" "分享码不能为空"
  share_code="$REPLY"

  echo -e "分享码导入方式:"
  echo -e "[1] 追加到现有规则"
  echo -e "[2] 覆盖现有规则"
  prompt_choice "请选择: " 1 2
  if [[ "$REPLY" == "1" ]]; then
    import_mode="append"
  else
    import_mode="overwrite"
  fi

  import_share_code_value "${share_code}" "${import_mode}"
}

function checknew() {
  if ! is_gost_installed; then
    echo -e "${Error} gost 尚未安装，无需更新。"
    return 1
  fi
  checknew=$(gost -V 2>&1 | awk '{print $2}')
  echo "你的gost版本为:${checknew:-未知}"
  if ask_yes_no "是否更新？[y/N]:" "n"; then
    Install_ct
  fi
}
function check_sys() {
  if [[ -f /etc/redhat-release ]]; then
    release="centos"
  elif [[ -f /etc/alpine-release ]]; then
    release="alpine"
  elif cat /etc/issue | grep -q -E -i "debian"; then
    release="debian"
  elif cat /etc/issue | grep -q -E -i "alpine"; then
    release="alpine"
  elif cat /etc/issue | grep -q -E -i "ubuntu"; then
    release="ubuntu"
  elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
    release="centos"
  elif cat /proc/version | grep -q -E -i "debian"; then
    release="debian"
  elif cat /proc/version | grep -q -E -i "alpine"; then
    release="alpine"
  elif cat /proc/version | grep -q -E -i "ubuntu"; then
    release="ubuntu"
  elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
    release="centos"
  fi
  if [[ -z "${release}" ]]; then
    release="unknown"
  fi
  if [[ "${release}" == "alpine" ]]; then
    service_manager="openrc"
  elif command -v systemctl >/dev/null 2>&1; then
    service_manager="systemd"
  elif command -v rc-service >/dev/null 2>&1; then
    service_manager="openrc"
  else
    service_manager="systemd"
  fi
  bit=$(uname -m)
  case "$bit" in
  x86_64)
    bit="amd64"
    ;;
  aarch64 | arm64)
    bit="arm64"
    ;;
  i386 | i686)
    bit="386"
    ;;
  *)
    prompt_choice "请输入你的芯片架构 [386/armv5/armv6/armv7/arm64/amd64]:" 386 armv5 armv6 armv7 arm64 amd64
    bit="$REPLY"
    ;;
  esac
}
function Installation_dependency() {
  if ! command -v gzip >/dev/null 2>&1 || ! command -v gunzip >/dev/null 2>&1 || { ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; }; then
    if [[ ${release} == "centos" ]]; then
      yum update
      yum install -y gzip wget curl ca-certificates
    elif [[ ${release} == "alpine" ]]; then
      apk update
      apk add gzip wget curl ca-certificates
    else
      apt-get update
      apt-get install -y gzip wget curl ca-certificates
    fi
  fi
}
function check_root() {
  [[ $EUID != 0 ]] && echo -e "${Error} 当前非ROOT账号(或没有ROOT权限)，无法继续操作，请更换ROOT账号或使用 ${Green_background_prefix}sudo su${Font_color_suffix} 命令获取临时ROOT权限（执行后可能会提示输入当前账号的密码）。" && exit 1
}
function check_new_ver() {
  # deprecated
  ct_new_ver=$(wget --no-check-certificate -qO- -t2 -T3 https://api.github.com/repos/ginuerzh/gost/releases/latest | grep "tag_name" | head -n 1 | awk -F ":" '{print $2}' | sed 's/\"//g;s/,//g;s/ //g;s/v//g')
  if [[ -z ${ct_new_ver} ]]; then
    ct_new_ver="2.11.2"
    echo -e "${Error} gost 最新版本获取失败，正在下载v${ct_new_ver}版"
  else
    echo -e "${Info} gost 目前最新版本为 ${ct_new_ver}"
  fi
}
function check_file() {
  if [[ "${service_manager}" == "openrc" ]]; then
    if test ! -d "/etc/init.d/"; then
      mkdir -p /etc/init.d
      chmod 755 /etc/init.d
    fi
    return 0
  fi
  if test ! -d "/usr/lib/systemd/system/"; then
    mkdir /usr/lib/systemd/system
    chmod 755 /usr/lib/systemd/system
  fi
}
function check_nor_file() {
  cleanup_temp
}
function Install_ct() {
  local source_mode=""
  local binary_url=""
  local service_url=""
  local config_url=""
  local binary_gz=""
  local binary_plain=""

  check_root
  check_nor_file
  check_sys
  Installation_dependency
  check_file

  if is_gost_installed; then
    echo -e "${Info} 检测到已安装 gost，本次将覆盖二进制和服务文件，并保留现有配置。"
  fi

  choose_download_source
  source_mode="${REPLY}"
  if [[ "${source_mode}" == "cn" ]]; then
    echo -e "${Info} 已自动选择大陆镜像下载。"
  else
    echo -e "${Info} 已自动选择海外源下载。"
  fi

  install_tmp_dir=$(make_temp_dir "gost-install") || {
    echo -e "${Error} 无法创建临时目录。"
    return 1
  }

  binary_gz="${install_tmp_dir}/gost-linux-${bit}-${ct_new_ver}.gz"
  binary_plain="${install_tmp_dir}/gost-linux-${bit}-${ct_new_ver}"

  if [[ "${source_mode}" == "cn" ]]; then
    binary_url="https://gotunnel.oss-cn-shenzhen.aliyuncs.com/gost-linux-${bit}-${ct_new_ver}.gz"
    service_url="https://gotunnel.oss-cn-shenzhen.aliyuncs.com/gost.service"
    config_url="https://gotunnel.oss-cn-shenzhen.aliyuncs.com/config.json"
  else
    binary_url="https://github.com/ginuerzh/gost/releases/download/v${ct_new_ver}/gost-linux-${bit}-${ct_new_ver}.gz"
    service_url="https://raw.githubusercontent.com/YeJianbo/Multi-EasyGost/v2/gost.service"
    config_url="https://raw.githubusercontent.com/YeJianbo/Multi-EasyGost/v2/config.json"
  fi

  if ! download_file "${binary_url}" "${binary_gz}"; then
    echo -e "${Error} gost 二进制下载失败。"
    return 1
  fi
  if ! gunzip -f "${binary_gz}"; then
    echo -e "${Error} gost 二进制解压失败。"
    return 1
  fi
  if [[ "${service_manager}" == "systemd" ]]; then
    if ! download_file "${service_url}" "${install_tmp_dir}/gost.service"; then
      echo -e "${Error} gost.service 下载失败。"
      return 1
    fi
  fi

  ensure_gost_dir
  if [[ ! -f "$gost_conf_path" ]]; then
    if ! download_file "${config_url}" "${install_tmp_dir}/config.json"; then
      echo -e "${Error} 默认配置下载失败。"
      return 1
    fi
    install -m 644 "${install_tmp_dir}/config.json" "$gost_conf_path"
  fi

  install -m 755 "${binary_plain}" /usr/bin/gost
  if [[ "${service_manager}" == "openrc" ]]; then
    write_openrc_service /etc/init.d/gost
    chmod 755 /etc/init.d/gost
  else
    install -m 644 "${install_tmp_dir}/gost.service" /usr/lib/systemd/system/gost.service
  fi
  ensure_raw_conf_file

  reload_service_manager
  enable_gost_service
  if ! service_action restart; then
    echo -e "${Error} gost 安装完成，但服务启动失败，请检查现有配置。"
    return 1
  fi

  echo "------------------------------"
  if test -a /usr/bin/gost -a "$(get_service_unit_path)" -a /etc/gost/config.json; then
    echo "gost安装成功"
  else
    echo "gost没有安装成功"
    return 1
  fi
}
function Uninstall_ct() {
  check_root
  check_sys
  if ! is_gost_installed; then
    echo -e "${Info} gost 当前未安装。"
    return 0
  fi
  service_action stop >/dev/null 2>&1
  disable_gost_service
  rm -rf /usr/bin/gost
  rm -rf /usr/lib/systemd/system/gost.service
  rm -rf /etc/init.d/gost
  rm -rf /etc/gost
  reload_service_manager
  echo "gost已经成功删除"
}
function Start_ct() {
  check_root
  check_sys
  if ! is_gost_installed; then
    echo -e "${Error} gost 尚未安装。"
    return 1
  fi
  service_action start
  echo "已启动"
}
function Stop_ct() {
  check_root
  check_sys
  if ! is_gost_installed; then
    echo -e "${Error} gost 尚未安装。"
    return 1
  fi
  service_action stop
  echo "已停止"
}
function Restart_ct() {
  if apply_runtime_config; then
    echo "已重读配置并重启"
  fi
}
function read_protocol() {
  echo -e "请问您要设置哪种功能: "
  echo -e "-----------------------------------"
  echo -e "[1] tcp+udp流量转发, 不加密"
  echo -e "说明: 一般设置在国内中转机上"
  echo -e "-----------------------------------"
  echo -e "[2] 加密隧道流量转发"
  echo -e "说明: 用于转发原本加密等级较低的流量, 一般设置在国内中转机上"
  echo -e "     选择此协议意味着你还有一台机器用于接收此加密流量, 之后须在那台机器上配置协议[3]进行对接"
  echo -e "-----------------------------------"
  echo -e "[3] 解密由gost传输而来的流量并转发"
  echo -e "说明: 对于经由gost加密中转的流量, 通过此选项进行解密并转发给本机的代理服务端口或转发给其他远程机器"
  echo -e "      一般设置在用于接收中转流量的国外机器上"
  echo -e "-----------------------------------"
  echo -e "[4] 一键安装ss/socks5/http代理"
  echo -e "说明: 使用gost内置的代理协议，轻量且易于管理"
  echo -e "-----------------------------------"
  echo -e "[5] 进阶：多落地均衡负载"
  echo -e "说明: 支持各种加密方式的简单均衡负载"
  echo -e "-----------------------------------"
  echo -e "[6] 进阶：转发CDN自选节点"
  echo -e "说明: 只需在中转机设置"
  echo -e "-----------------------------------"
  prompt_choice "请选择: " 1 2 3 4 5 6
  numprotocol="$REPLY"

  case "$numprotocol" in
  1) flag_a="nonencrypt" ;;
  2) encrypt ;;
  3) decrypt ;;
  4) proxy ;;
  5) enpeer ;;
  6) cdn ;;
  esac
}
function read_s_port() {
  if [ "$flag_a" == "ss" ]; then
    echo -e "-----------------------------------"
    prompt_nonempty "请输入ss密码: " validate_no_space_or_delimiter "密码不能为空，且不能包含空格或 #"
    flag_b="$REPLY"
  elif [ "$flag_a" == "socks" ]; then
    echo -e "-----------------------------------"
    prompt_nonempty "请输入socks密码: " validate_no_space_or_delimiter "密码不能为空，且不能包含空格或 #"
    flag_b="$REPLY"
  elif [ "$flag_a" == "http" ]; then
    echo -e "-----------------------------------"
    prompt_nonempty "请输入http密码: " validate_no_space_or_delimiter "密码不能为空，且不能包含空格或 #"
    flag_b="$REPLY"
  else
    echo -e "------------------------------------------------------------------"
    echo -e "请问你要将本机哪个端口接收到的流量进行转发?"
    prompt_nonempty "请输入: " validate_port "请输入合法端口（1-65535）"
    flag_b="$REPLY"
  fi
}
function read_d_ip() {
  if [ "$flag_a" == "ss" ]; then
    echo -e "------------------------------------------------------------------"
    echo -e "请问您要设置的ss加密(仅提供常用的几种): "
    echo -e "-----------------------------------"
    echo -e "[1] aes-256-gcm"
    echo -e "[2] aes-256-cfb"
    echo -e "[3] chacha20-ietf-poly1305"
    echo -e "[4] chacha20"
    echo -e "[5] rc4-md5"
    echo -e "[6] AEAD_CHACHA20_POLY1305"
    echo -e "-----------------------------------"
    prompt_choice "请选择ss加密方式: " 1 2 3 4 5 6
    ssencrypt="$REPLY"

    case "$ssencrypt" in
    1) flag_c="aes-256-gcm" ;;
    2) flag_c="aes-256-cfb" ;;
    3) flag_c="chacha20-ietf-poly1305" ;;
    4) flag_c="chacha20" ;;
    5) flag_c="rc4-md5" ;;
    6) flag_c="AEAD_CHACHA20_POLY1305" ;;
    esac
  elif [ "$flag_a" == "socks" ]; then
    echo -e "-----------------------------------"
    prompt_nonempty "请输入socks用户名: " validate_no_space_or_delimiter "用户名不能为空，且不能包含空格或 #"
    flag_c="$REPLY"
  elif [ "$flag_a" == "http" ]; then
    echo -e "-----------------------------------"
    prompt_nonempty "请输入http用户名: " validate_no_space_or_delimiter "用户名不能为空，且不能包含空格或 #"
    flag_c="$REPLY"
  elif [[ "$flag_a" == "peer"* ]]; then
    echo -e "------------------------------------------------------------------"
    echo -e "请输入落地列表文件名"
    while true; do
      prompt_nonempty "自定义但不同配置应不重复，不用输入后缀，例如ips1、iplist2: " validate_filename_token "文件名只能包含字母、数字、点、下划线或中划线"
      flag_c="$REPLY"
      if [[ -e "/root/${flag_c}.txt" ]]; then
        echo "文件 /root/${flag_c}.txt 已存在，请更换名称。"
      else
        break
      fi
    done
    peer_tmp_file="/root/${flag_c}.txt"
    touch "$peer_tmp_file"
    echo -e "------------------------------------------------------------------"
    echo -e "请依次输入你要均衡负载的落地ip与端口"
    while true; do
      echo -e "请问你要将本机从${flag_b}接收到的流量转发向的IP或域名?"
      prompt_nonempty "请输入: " validate_host "请输入合法的 IP 或域名"
      peer_ip=$(normalize_host "$REPLY")
      echo -e "请问你要将本机从${flag_b}接收到的流量转发向${peer_ip}的哪个端口?"
      prompt_nonempty "请输入: " validate_port "请输入合法端口（1-65535）"
      peer_port="$REPLY"
      echo -e "$peer_ip:$peer_port" >>"$peer_tmp_file"
      if ! ask_yes_no "是否继续添加落地？[Y/n]:" "y"; then
        echo -e "------------------------------------------------------------------"
        echo -e "已在root目录创建${flag_c}.txt，您可以随时编辑该文件修改落地信息，重启gost即可生效"
        echo -e "------------------------------------------------------------------"
        peer_tmp_file=""
        break
      else
        echo -e "------------------------------------------------------------------"
        echo -e "继续添加均衡负载落地配置"
      fi
    done
  elif [[ "$flag_a" == "cdn"* ]]; then
    echo -e "------------------------------------------------------------------"
    echo -e "将本机从${flag_b}接收到的流量转发向的自选ip:"
    prompt_nonempty "请输入: " validate_host "请输入合法的 IP 或域名"
    flag_c=$(normalize_host "$REPLY")
    echo -e "请问你要将本机从${flag_b}接收到的流量转发向${flag_c}的哪个端口?"
    echo -e "[1] 80"
    echo -e "[2] 443"
    echo -e "[3] 自定义端口（如8080等）"
    prompt_choice "请选择端口: " 1 2 3
    cdnport="$REPLY"
    if [ "$cdnport" == "1" ]; then
      flag_c="$flag_c:80"
    elif [ "$cdnport" == "2" ]; then
      flag_c="$flag_c:443"
    elif [ "$cdnport" == "3" ]; then
      prompt_nonempty "请输入自定义端口: " validate_port "请输入合法端口（1-65535）"
      customport="$REPLY"
      flag_c="$flag_c:$customport"
    fi
  else
    echo -e "------------------------------------------------------------------"
    echo -e "请问你要将本机从${flag_b}接收到的流量转发向哪个IP或域名?"
    echo -e "注: IP既可以是[远程机器/当前机器]的公网IP, 也可是以本机本地回环IP(即127.0.0.1)"
    echo -e "具体IP地址的填写, 取决于接收该流量的服务正在监听的IP(详见: https://github.com/YeJianbo/Multi-EasyGost)"
    if [[ ${is_cert} == [Yy] ]]; then
      echo -e "注意: 落地机开启自定义tls证书，务必填写${Red_font_prefix}域名${Font_color_suffix}"
      prompt_nonempty "请输入: " validate_host_header "请输入合法域名"
      flag_c="$REPLY"
    else
      prompt_nonempty "请输入: " validate_host "请输入合法的 IP 或域名"
      flag_c=$(normalize_host "$REPLY")
    fi
  fi
}
function read_d_port() {
  if [ "$flag_a" == "ss" ]; then
    echo -e "------------------------------------------------------------------"
    echo -e "请问你要设置ss代理服务的端口?"
    prompt_nonempty "请输入: " validate_port "请输入合法端口（1-65535）"
    flag_d="$REPLY"
  elif [ "$flag_a" == "socks" ]; then
    echo -e "------------------------------------------------------------------"
    echo -e "请问你要设置socks代理服务的端口?"
    prompt_nonempty "请输入: " validate_port "请输入合法端口（1-65535）"
    flag_d="$REPLY"
  elif [ "$flag_a" == "http" ]; then
    echo -e "------------------------------------------------------------------"
    echo -e "请问你要设置http代理服务的端口?"
    prompt_nonempty "请输入: " validate_port "请输入合法端口（1-65535）"
    flag_d="$REPLY"
  elif [[ "$flag_a" == "peer"* ]]; then
    echo -e "------------------------------------------------------------------"
    echo -e "您要设置的均衡负载策略: "
    echo -e "-----------------------------------"
    echo -e "[1] round - 轮询"
    echo -e "[2] random - 随机"
    echo -e "[3] fifo - 自上而下"
    echo -e "-----------------------------------"
    prompt_choice "请选择均衡负载类型: " 1 2 3
    numstra="$REPLY"

    case "$numstra" in
    1) flag_d="round" ;;
    2) flag_d="random" ;;
    3) flag_d="fifo" ;;
    esac
  elif [[ "$flag_a" == "cdn"* ]]; then
    echo -e "------------------------------------------------------------------"
    prompt_nonempty "请输入host: " validate_host_header "请输入合法 Host"
    flag_d="$REPLY"
  else
    echo -e "------------------------------------------------------------------"
    echo -e "请问你要将本机从${flag_b}接收到的流量转发向${flag_c}的哪个端口?"
    prompt_nonempty "请输入: " validate_port "请输入合法端口（1-65535）"
    flag_d="$REPLY"
    if [[ ${is_cert} == [Yy] ]]; then
      flag_d="$flag_d?secure=true"
    fi
  fi
}
function writerawconf() {
  local target_rawconf="${1:-$raw_conf_path}"
  ensure_gost_dir
  touch "$target_rawconf"
  echo "${flag_a}/${flag_b}#${flag_c}#${flag_d}" >>"$target_rawconf"
}
function rawconf() {
  local target_rawconf="${1:-$raw_conf_path}"
  flag_a=""
  flag_b=""
  flag_c=""
  flag_d=""
  is_cert="n"
  read_protocol
  read_s_port
  read_d_ip
  read_d_port
  writerawconf "$target_rawconf"
}
function eachconf_retrieve() {
  d_server=${trans_conf#*#}
  d_port=${d_server#*#}
  d_ip=${d_server%#*}
  flag_s_port=${trans_conf%%#*}
  s_port=${flag_s_port#*/}
  is_encrypt=${flag_s_port%/*}
}
function get_rule_display_name() {
  if [ "$is_encrypt" == "nonencrypt" ]; then
    str="不加密中转"
  elif [ "$is_encrypt" == "encrypttls" ]; then
    str=" tls隧道 "
  elif [ "$is_encrypt" == "encryptws" ]; then
    str="  ws隧道 "
  elif [ "$is_encrypt" == "encryptwss" ]; then
    str=" wss隧道 "
  elif [ "$is_encrypt" == "encryptquic" ]; then
    str="quic隧道 "
  elif [ "$is_encrypt" == "encryptkcp" ]; then
    str=" kcp隧道 "
  elif [ "$is_encrypt" == "peerno" ]; then
    str=" 不加密均衡负载 "
  elif [ "$is_encrypt" == "peertls" ]; then
    str=" tls隧道均衡负载 "
  elif [ "$is_encrypt" == "peerws" ]; then
    str="  ws隧道均衡负载 "
  elif [ "$is_encrypt" == "peerwss" ]; then
    str=" wss隧道均衡负载 "
  elif [ "$is_encrypt" == "peerquic" ]; then
    str="quic隧道均衡负载"
  elif [ "$is_encrypt" == "peerkcp" ]; then
    str=" kcp隧道均衡负载"
  elif [ "$is_encrypt" == "decrypttls" ]; then
    str=" tls解密 "
  elif [ "$is_encrypt" == "decryptws" ]; then
    str="  ws解密 "
  elif [ "$is_encrypt" == "decryptwss" ]; then
    str=" wss解密 "
  elif [ "$is_encrypt" == "decryptquic" ]; then
    str="quic解密 "
  elif [ "$is_encrypt" == "decryptkcp" ]; then
    str=" kcp解密 "
  elif [ "$is_encrypt" == "ss" ]; then
    str="   ss   "
  elif [ "$is_encrypt" == "socks" ]; then
    str=" socks5 "
  elif [ "$is_encrypt" == "http" ]; then
    str=" http "
  elif [ "$is_encrypt" == "cdnno" ]; then
    str="不加密转发CDN"
  elif [ "$is_encrypt" == "cdnws" ]; then
    str="ws隧道转发CDN"
  elif [ "$is_encrypt" == "cdnwss" ]; then
    str="wss隧道转发CDN"
  else
    str=""
  fi
}

show_rawconf_preview() {
  local source_rawconf="$1"
  local title="$2"
  local count_line=0
  local preview_index=0
  if [[ ! -s "${source_rawconf}" ]]; then
    echo -e "${Info} ${title}为空。"
    return 0
  fi
  [[ -n "${title}" ]] && echo -e "${title}"
  echo -e "--------------------------------------------------------"
  echo -e "序号|方法\t    |本地端口\t|目的地地址:目的地端口"
  echo -e "--------------------------------------------------------"
  count_line=$(awk 'END{print NR}' "${source_rawconf}")
  for ((preview_index = 1; preview_index <= count_line; preview_index++)); do
    trans_conf=$(sed -n "${preview_index}p" "${source_rawconf}")
    eachconf_retrieve
    get_rule_display_name
    echo -e " ${preview_index}  |$str  |$s_port\t|$d_ip:$d_port"
    echo -e "--------------------------------------------------------"
  done
}

count_rules_in_rawconf() {
  local source_rawconf="$1"
  if [[ ! -s "${source_rawconf}" ]]; then
    printf '0'
    return 0
  fi
  awk 'END{print NR}' "${source_rawconf}"
}

confirm_import_preview() {
  local imported_rawconf="$1"
  local import_mode="$2"
  local current_count=0
  local import_count=0

  current_count=$(count_rules_in_rawconf "$raw_conf_path")
  import_count=$(count_rules_in_rawconf "${imported_rawconf}")

  echo -e "${Info} 当前规则数：${current_count}"
  if [[ "${import_mode}" == "append" ]]; then
    echo -e "${Info} 本次将追加 ${import_count} 条规则。"
    show_rawconf_preview "${imported_rawconf}" "即将追加的规则："
  else
    echo -e "${Info} 本次将覆盖当前规则，并导入 ${import_count} 条规则。"
    show_rawconf_preview "${imported_rawconf}" "即将覆盖生效的规则："
  fi
  ask_yes_no "确认继续导入？[y/N]:" "n"
}
function confstart() {
  echo "{
    \"Debug\": true,
    \"Retries\": 0,
    \"ServeNodes\": [" >>$gost_conf_path
}
function multiconfstart() {
  echo "        {
            \"Retries\": 0,
            \"ServeNodes\": [" >>$gost_conf_path
}
function conflast() {
  echo "    ]
}" >>$gost_conf_path
}
function multiconflast() {
  if [ $i -eq $count_line ]; then
    echo "            ]
        }" >>$gost_conf_path
  else
    echo "            ]
        }," >>$gost_conf_path
  fi
}
function encrypt() {
  echo -e "请问您要设置的转发传输类型: "
  echo -e "-----------------------------------"
  echo -e "[1] tls隧道"
  echo -e "[2] ws隧道"
  echo -e "[3] wss隧道"
  echo -e "[4] quic隧道"
  echo -e "[5] kcp隧道"
  echo -e "注意: 同一则转发，中转与落地传输类型必须对应！本脚本默认开启tcp+udp"
  echo -e "提示: quic/kcp 依赖 UDP，请同时放行对应端口的 UDP 入站"
  echo -e "-----------------------------------"
  prompt_choice "请选择转发传输类型: " 1 2 3 4 5
  numencrypt="$REPLY"

  if [ "$numencrypt" == "1" ]; then
    flag_a="encrypttls"
    echo -e "注意: 选择 是 将针对落地的自定义证书开启证书校验保证安全性，稍后落地机务必填写${Red_font_prefix}域名${Font_color_suffix}"
    if ask_yes_no "落地机是否开启了自定义tls证书？[y/N]:" "n"; then
      is_cert="y"
    else
      is_cert="n"
    fi
  elif [ "$numencrypt" == "2" ]; then
    flag_a="encryptws"
  elif [ "$numencrypt" == "3" ]; then
    flag_a="encryptwss"
    echo -e "注意: 选择 是 将针对落地的自定义证书开启证书校验保证安全性，稍后落地机务必填写${Red_font_prefix}域名${Font_color_suffix}"
    if ask_yes_no "落地机是否开启了自定义tls证书？[y/N]:" "n"; then
      is_cert="y"
    else
      is_cert="n"
    fi
  elif [ "$numencrypt" == "4" ]; then
    flag_a="encryptquic"
    echo -e "注意: 选择 是 将针对落地的自定义证书开启证书校验保证安全性，稍后落地机务必填写${Red_font_prefix}域名${Font_color_suffix}"
    if ask_yes_no "落地机是否开启了自定义tls证书？[y/N]:" "n"; then
      is_cert="y"
    else
      is_cert="n"
    fi
  elif [ "$numencrypt" == "5" ]; then
    flag_a="encryptkcp"
  fi
}
function enpeer() {
  echo -e "请问您要设置的均衡负载传输类型: "
  echo -e "-----------------------------------"
  echo -e "[1] 不加密转发"
  echo -e "[2] tls隧道"
  echo -e "[3] ws隧道"
  echo -e "[4] wss隧道"
  echo -e "[5] quic隧道"
  echo -e "[6] kcp隧道"
  echo -e "注意: 同一则转发，中转与落地传输类型必须对应！本脚本默认同一配置的传输类型相同"
  echo -e "提示: quic/kcp 依赖 UDP，请同时放行对应端口的 UDP 入站"
  echo -e "此脚本仅支持简单型均衡负载，具体可参考官方文档"
  echo -e "gost均衡负载官方文档：https://docs.ginuerzh.xyz/gost/load-balancing"
  echo -e "-----------------------------------"
  prompt_choice "请选择转发传输类型: " 1 2 3 4 5 6
  numpeer="$REPLY"

  if [ "$numpeer" == "1" ]; then
    flag_a="peerno"
  elif [ "$numpeer" == "2" ]; then
    flag_a="peertls"
  elif [ "$numpeer" == "3" ]; then
    flag_a="peerws"
  elif [ "$numpeer" == "4" ]; then
    flag_a="peerwss"
  elif [ "$numpeer" == "5" ]; then
    flag_a="peerquic"
  elif [ "$numpeer" == "6" ]; then
    flag_a="peerkcp"
  fi
}
function cdn() {
  echo -e "请问您要设置的CDN传输类型: "
  echo -e "-----------------------------------"
  echo -e "[1] 不加密转发"
  echo -e "[2] ws隧道"
  echo -e "[3] wss隧道"
  echo -e "注意: 同一则转发，中转与落地传输类型必须对应！"
  echo -e "此功能只需在中转机设置"
  echo -e "-----------------------------------"
  prompt_choice "请选择CDN转发传输类型: " 1 2 3
  numcdn="$REPLY"

  if [ "$numcdn" == "1" ]; then
    flag_a="cdnno"
  elif [ "$numcdn" == "2" ]; then
    flag_a="cdnws"
  elif [ "$numcdn" == "3" ]; then
    flag_a="cdnwss"
  fi
}
function cert() {
  echo -e "-----------------------------------"
  echo -e "[1] ACME一键申请证书"
  echo -e "[2] 手动上传证书"
  echo -e "-----------------------------------"
  echo -e "说明: 仅用于落地机配置，默认使用的gost内置的证书可能带来安全问题，使用自定义证书提高安全性"
  echo -e "     配置后对本机所有tls/wss解密生效，无需再次设置"
  prompt_choice "请选择证书生成方式: " 1 2
  numcert="$REPLY"

  if [ "$numcert" == "1" ]; then
    check_sys
    if [[ ${release} == "centos" ]]; then
      yum install -y socat
    elif [[ ${release} == "alpine" ]]; then
      apk add socat
    else
      apt-get install -y socat
    fi
    prompt_nonempty "请输入ZeroSSL的账户邮箱(至 zerossl.com 注册即可)：" "" "邮箱不能为空"
    zeromail="$REPLY"
    prompt_nonempty "请输入解析到本机的域名：" validate_host_header "请输入合法域名"
    domain="$REPLY"
    curl https://get.acme.sh | sh
    "$HOME"/.acme.sh/acme.sh --set-default-ca --server zerossl
    "$HOME"/.acme.sh/acme.sh --register-account -m "${zeromail}" --server zerossl
    echo -e "ACME证书申请程序安装成功"
    echo -e "-----------------------------------"
    echo -e "[1] HTTP申请（需要80端口未占用）"
    echo -e "[2] Cloudflare DNS API 申请（需要输入APIKEY）"
    echo -e "-----------------------------------"
    prompt_choice "请选择证书申请方式: " 1 2
    certmethod="$REPLY"
    if [ "$certmethod" == "1" ]; then
      echo -e "请确认本机${Red_font_prefix}80${Font_color_suffix}端口未被占用, 否则会申请失败"
      if "$HOME"/.acme.sh/acme.sh --issue -d "${domain}" --standalone -k ec-256 --force; then
        echo -e "SSL 证书生成成功，默认申请高安全性的ECC证书"
        if [ ! -d "$HOME/gost_cert" ]; then
          mkdir $HOME/gost_cert
        fi
        if "$HOME"/.acme.sh/acme.sh --installcert -d "${domain}" --fullchainpath $HOME/gost_cert/cert.pem --keypath $HOME/gost_cert/key.pem --ecc --force; then
          echo -e "SSL 证书配置成功，且会自动续签，证书及秘钥位于用户目录下的 ${Red_font_prefix}gost_cert${Font_color_suffix} 目录"
          echo -e "证书目录名与证书文件名请勿更改; 删除 gost_cert 目录后用脚本重启,即自动启用gost内置证书"
          echo -e "-----------------------------------"
        fi
      else
        echo -e "SSL 证书生成失败"
        exit 1
      fi
    else
      prompt_nonempty "请输入Cloudflare账户邮箱：" "" "邮箱不能为空"
      cfmail="$REPLY"
      prompt_nonempty "请输入Cloudflare Global API Key：" "" "API Key 不能为空"
      cfkey="$REPLY"
      export CF_Key="${cfkey}"
      export CF_Email="${cfmail}"
      if "$HOME"/.acme.sh/acme.sh --issue --dns dns_cf -d "${domain}" --standalone -k ec-256 --force; then
        echo -e "SSL 证书生成成功，默认申请高安全性的ECC证书"
        if [ ! -d "$HOME/gost_cert" ]; then
          mkdir $HOME/gost_cert
        fi
        if "$HOME"/.acme.sh/acme.sh --installcert -d "${domain}" --fullchainpath $HOME/gost_cert/cert.pem --keypath $HOME/gost_cert/key.pem --ecc --force; then
          echo -e "SSL 证书配置成功，且会自动续签，证书及秘钥位于用户目录下的 ${Red_font_prefix}gost_cert${Font_color_suffix} 目录"
          echo -e "证书目录名与证书文件名请勿更改; 删除 gost_cert 目录后使用脚本重启, 即重新启用gost内置证书"
          echo -e "-----------------------------------"
        fi
      else
        echo -e "SSL 证书生成失败"
        exit 1
      fi
    fi

  elif [ "$numcert" == "2" ]; then
    if [ ! -d "$HOME/gost_cert" ]; then
      mkdir $HOME/gost_cert
    fi
    echo -e "-----------------------------------"
    echo -e "已在用户目录建立 ${Red_font_prefix}gost_cert${Font_color_suffix} 目录，请将证书文件 cert.pem 与秘钥文件 key.pem 上传到该目录"
    echo -e "证书与秘钥文件名必须与上述一致，目录名也请勿更改"
    echo -e "上传成功后，用脚本重启gost会自动启用，无需再设置; 删除 gost_cert 目录后用脚本重启,即重新启用gost内置证书"
    echo -e "-----------------------------------"
  fi
}
function decrypt() {
  echo -e "请问您要设置的解密传输类型: "
  echo -e "-----------------------------------"
  echo -e "[1] tls"
  echo -e "[2] ws"
  echo -e "[3] wss"
  echo -e "[4] quic"
  echo -e "[5] kcp"
  echo -e "注意: 同一则转发，中转与落地传输类型必须对应！本脚本默认开启tcp+udp"
  echo -e "提示: quic/kcp 依赖 UDP，请同时放行对应端口的 UDP 入站"
  echo -e "-----------------------------------"
  prompt_choice "请选择解密传输类型: " 1 2 3 4 5
  numdecrypt="$REPLY"

  if [ "$numdecrypt" == "1" ]; then
    flag_a="decrypttls"
  elif [ "$numdecrypt" == "2" ]; then
    flag_a="decryptws"
  elif [ "$numdecrypt" == "3" ]; then
    flag_a="decryptwss"
  elif [ "$numdecrypt" == "4" ]; then
    flag_a="decryptquic"
  elif [ "$numdecrypt" == "5" ]; then
    flag_a="decryptkcp"
  fi
}
function proxy() {
  echo -e "------------------------------------------------------------------"
  echo -e "请问您要设置的代理类型: "
  echo -e "-----------------------------------"
  echo -e "[1] shadowsocks"
  echo -e "[2] socks5(强烈建议加隧道用于Telegram代理)"
  echo -e "[3] http"
  echo -e "-----------------------------------"
  prompt_choice "请选择代理类型: " 1 2 3
  numproxy="$REPLY"
  if [ "$numproxy" == "1" ]; then
    flag_a="ss"
  elif [ "$numproxy" == "2" ]; then
    flag_a="socks"
  elif [ "$numproxy" == "3" ]; then
    flag_a="http"
  fi
}
function method() {
  if [ $i -eq 1 ]; then
    if [ "$is_encrypt" == "nonencrypt" ]; then
      echo "        \"tcp://:$s_port/$d_ip:$d_port\",
        \"udp://:$s_port/$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "cdnno" ]; then
      echo "        \"tcp://:$s_port/$d_ip?host=$d_port\",
        \"udp://:$s_port/$d_ip?host=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "peerno" ]; then
      echo "        \"tcp://:$s_port?ip=/root/$d_ip.txt&strategy=$d_port\",
        \"udp://:$s_port?ip=/root/$d_ip.txt&strategy=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "encrypttls" ]; then
      echo "        \"tcp://:$s_port\",
        \"udp://:$s_port\"
    ],
    \"ChainNodes\": [
        \"relay+tls://$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "encryptws" ]; then
      echo "        \"tcp://:$s_port\",
    	\"udp://:$s_port\"
	],
	\"ChainNodes\": [
    	\"relay+ws://$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "encryptwss" ]; then
      echo "        \"tcp://:$s_port\",
		  \"udp://:$s_port\"
	],
	\"ChainNodes\": [
		\"relay+wss://$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "encryptquic" ]; then
      echo "        \"tcp://:$s_port\",
        \"udp://:$s_port\"
    ],
    \"ChainNodes\": [
        \"relay+quic://$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "encryptkcp" ]; then
      echo "        \"tcp://:$s_port\",
        \"udp://:$s_port\"
    ],
    \"ChainNodes\": [
        \"relay+kcp://$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "peertls" ]; then
      echo "        \"tcp://:$s_port\",
    	\"udp://:$s_port\"
	],
	\"ChainNodes\": [
    	\"relay+tls://:?ip=/root/$d_ip.txt&strategy=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "peerws" ]; then
      echo "        \"tcp://:$s_port\",
    	\"udp://:$s_port\"
	],
	\"ChainNodes\": [
    	\"relay+ws://:?ip=/root/$d_ip.txt&strategy=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "peerwss" ]; then
      echo "        \"tcp://:$s_port\",
    	\"udp://:$s_port\"
	],
	\"ChainNodes\": [
    	\"relay+wss://:?ip=/root/$d_ip.txt&strategy=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "peerquic" ]; then
      echo "        \"tcp://:$s_port\",
        \"udp://:$s_port\"
    ],
    \"ChainNodes\": [
        \"relay+quic://:?ip=/root/$d_ip.txt&strategy=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "peerkcp" ]; then
      echo "        \"tcp://:$s_port\",
        \"udp://:$s_port\"
    ],
    \"ChainNodes\": [
        \"relay+kcp://:?ip=/root/$d_ip.txt&strategy=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "cdnws" ]; then
      echo "        \"tcp://:$s_port\",
    	\"udp://:$s_port\"
	],
	\"ChainNodes\": [
    	\"relay+ws://$d_ip?host=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "cdnwss" ]; then
      echo "        \"tcp://:$s_port\",
    	\"udp://:$s_port\"
	],
	\"ChainNodes\": [
    	\"relay+wss://$d_ip?host=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "decrypttls" ]; then
      if [ -d "$HOME/gost_cert" ]; then
        echo "        \"relay+tls://:$s_port/$d_ip:$d_port?cert=/root/gost_cert/cert.pem&key=/root/gost_cert/key.pem\"" >>$gost_conf_path
      else
        echo "        \"relay+tls://:$s_port/$d_ip:$d_port\"" >>$gost_conf_path
      fi
    elif [ "$is_encrypt" == "decryptws" ]; then
      echo "        \"relay+ws://:$s_port/$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "decryptwss" ]; then
      if [ -d "$HOME/gost_cert" ]; then
        echo "        \"relay+wss://:$s_port/$d_ip:$d_port?cert=/root/gost_cert/cert.pem&key=/root/gost_cert/key.pem\"" >>$gost_conf_path
      else
        echo "        \"relay+wss://:$s_port/$d_ip:$d_port\"" >>$gost_conf_path
      fi
    elif [ "$is_encrypt" == "decryptquic" ]; then
      if [ -d "$HOME/gost_cert" ]; then
        echo "        \"relay+quic://:$s_port/$d_ip:$d_port?cert=/root/gost_cert/cert.pem&key=/root/gost_cert/key.pem\"" >>$gost_conf_path
      else
        echo "        \"relay+quic://:$s_port/$d_ip:$d_port\"" >>$gost_conf_path
      fi
    elif [ "$is_encrypt" == "decryptkcp" ]; then
      echo "        \"relay+kcp://:$s_port/$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "ss" ]; then
      echo "        \"ss://$d_ip:$s_port@:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "socks" ]; then
      echo "        \"socks5://$d_ip:$s_port@:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "http" ]; then
      echo "        \"http://$d_ip:$s_port@:$d_port\"" >>$gost_conf_path
    else
      echo "config error"
    fi
  elif [ $i -gt 1 ]; then
    if [ "$is_encrypt" == "nonencrypt" ]; then
      echo "                \"tcp://:$s_port/$d_ip:$d_port\",
                \"udp://:$s_port/$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "peerno" ]; then
      echo "                \"tcp://:$s_port?ip=/root/$d_ip.txt&strategy=$d_port\",
                \"udp://:$s_port?ip=/root/$d_ip.txt&strategy=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "cdnno" ]; then
      echo "                \"tcp://:$s_port/$d_ip?host=$d_port\",
                \"udp://:$s_port/$d_ip?host=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "encrypttls" ]; then
      echo "                \"tcp://:$s_port\",
                \"udp://:$s_port\"
            ],
            \"ChainNodes\": [
                \"relay+tls://$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "encryptws" ]; then
      echo "                \"tcp://:$s_port\",
	            \"udp://:$s_port\"
	        ],
	        \"ChainNodes\": [
	            \"relay+ws://$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "encryptwss" ]; then
      echo "                \"tcp://:$s_port\",
		        \"udp://:$s_port\"
		    ],
		    \"ChainNodes\": [
		        \"relay+wss://$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "encryptquic" ]; then
      echo "                \"tcp://:$s_port\",
                \"udp://:$s_port\"
            ],
            \"ChainNodes\": [
                \"relay+quic://$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "encryptkcp" ]; then
      echo "                \"tcp://:$s_port\",
                \"udp://:$s_port\"
            ],
            \"ChainNodes\": [
                \"relay+kcp://$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "peertls" ]; then
      echo "                \"tcp://:$s_port\",
                \"udp://:$s_port\"
            ],
            \"ChainNodes\": [
                \"relay+tls://:?ip=/root/$d_ip.txt&strategy=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "peerws" ]; then
      echo "                \"tcp://:$s_port\",
                \"udp://:$s_port\"
            ],
            \"ChainNodes\": [
                \"relay+ws://:?ip=/root/$d_ip.txt&strategy=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "peerwss" ]; then
      echo "                \"tcp://:$s_port\",
                \"udp://:$s_port\"
            ],
            \"ChainNodes\": [
                \"relay+wss://:?ip=/root/$d_ip.txt&strategy=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "peerquic" ]; then
      echo "                \"tcp://:$s_port\",
                \"udp://:$s_port\"
            ],
            \"ChainNodes\": [
                \"relay+quic://:?ip=/root/$d_ip.txt&strategy=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "peerkcp" ]; then
      echo "                \"tcp://:$s_port\",
                \"udp://:$s_port\"
            ],
            \"ChainNodes\": [
                \"relay+kcp://:?ip=/root/$d_ip.txt&strategy=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "cdnws" ]; then
      echo "                \"tcp://:$s_port\",
                \"udp://:$s_port\"
            ],
            \"ChainNodes\": [
                \"relay+ws://$d_ip?host=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "cdnwss" ]; then
      echo "                 \"tcp://:$s_port\",
                \"udp://:$s_port\"
            ],
            \"ChainNodes\": [
                \"relay+wss://$d_ip?host=$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "decrypttls" ]; then
      if [ -d "$HOME/gost_cert" ]; then
        echo "        		  \"relay+tls://:$s_port/$d_ip:$d_port?cert=/root/gost_cert/cert.pem&key=/root/gost_cert/key.pem\"" >>$gost_conf_path
      else
        echo "        		  \"relay+tls://:$s_port/$d_ip:$d_port\"" >>$gost_conf_path
      fi
    elif [ "$is_encrypt" == "decryptws" ]; then
      echo "        		  \"relay+ws://:$s_port/$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "decryptwss" ]; then
      if [ -d "$HOME/gost_cert" ]; then
        echo "        		  \"relay+wss://:$s_port/$d_ip:$d_port?cert=/root/gost_cert/cert.pem&key=/root/gost_cert/key.pem\"" >>$gost_conf_path
      else
        echo "        		  \"relay+wss://:$s_port/$d_ip:$d_port\"" >>$gost_conf_path
      fi
    elif [ "$is_encrypt" == "decryptquic" ]; then
      if [ -d "$HOME/gost_cert" ]; then
        echo "                  \"relay+quic://:$s_port/$d_ip:$d_port?cert=/root/gost_cert/cert.pem&key=/root/gost_cert/key.pem\"" >>$gost_conf_path
      else
        echo "                  \"relay+quic://:$s_port/$d_ip:$d_port\"" >>$gost_conf_path
      fi
    elif [ "$is_encrypt" == "decryptkcp" ]; then
      echo "                  \"relay+kcp://:$s_port/$d_ip:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "ss" ]; then
      echo "        \"ss://$d_ip:$s_port@:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "socks" ]; then
      echo "        \"socks5://$d_ip:$s_port@:$d_port\"" >>$gost_conf_path
    elif [ "$is_encrypt" == "http" ]; then
      echo "        \"http://$d_ip:$s_port@:$d_port\"" >>$gost_conf_path
    else
      echo "config error"
    fi
  else
    echo "config error"
    exit
  fi
}

function writeconf() {
  if [[ ! -s "$raw_conf_path" ]]; then
    return 0
  fi
  count_line=$(awk 'END{print NR}' $raw_conf_path)
  for ((i = 1; i <= $count_line; i++)); do
    if [ $i -eq 1 ]; then
      trans_conf=$(sed -n "${i}p" $raw_conf_path)
      eachconf_retrieve
      method
    elif [ $i -gt 1 ]; then
      if [ $i -eq 2 ]; then
        echo "    ],
    \"Routes\": [" >>$gost_conf_path
        trans_conf=$(sed -n "${i}p" $raw_conf_path)
        eachconf_retrieve
        multiconfstart
        method
        multiconflast
      else
        trans_conf=$(sed -n "${i}p" $raw_conf_path)
        eachconf_retrieve
        multiconfstart
        method
        multiconflast
      fi
    fi
  done
}
function show_all_conf() {
  ensure_raw_conf_file
  if [[ ! -s "$raw_conf_path" ]]; then
    echo -e "${Info} 当前没有任何 gost 配置。"
    return 0
  fi
  echo -e "                      GOST 配置                        "
  show_rawconf_preview "$raw_conf_path" ""
}

cron_restart() {
  check_sys
  echo -e "------------------------------------------------------------------"
  echo -e "gost定时重启任务: "
  echo -e "-----------------------------------"
  echo -e "[1] 配置gost定时重启任务"
  echo -e "[2] 删除gost定时重启任务"
  echo -e "-----------------------------------"
  prompt_choice "请选择: " 1 2
  numcron="$REPLY"
  if [ "$numcron" == "1" ]; then
    echo -e "------------------------------------------------------------------"
    echo -e "gost定时重启任务类型: "
    echo -e "-----------------------------------"
    echo -e "[1] 每？小时重启"
    echo -e "[2] 每日？点重启"
    echo -e "-----------------------------------"
    prompt_choice "请选择: " 1 2
    numcrontype="$REPLY"
    if [ "$numcrontype" == "1" ]; then
      echo -e "-----------------------------------"
      prompt_nonempty "每？小时重启: " validate_menu_number "请输入正整数小时数"
      cronhr="$REPLY"
      if [[ "${release}" == "alpine" ]]; then
        append_cron_line "0 */$cronhr * * * $(get_restart_command)"
      else
        append_cron_line "0 */$cronhr * * * root $(get_restart_command)"
      fi
      echo -e "定时重启设置成功！"
    elif [ "$numcrontype" == "2" ]; then
      echo -e "-----------------------------------"
      prompt_nonempty "每日？点重启: " validate_menu_number "请输入 0-23 的整数"
      cronhr="$REPLY"
      if ((10#$cronhr < 0 || 10#$cronhr > 23)); then
        echo "请输入 0-23 的整数"
        return 1
      fi
      if [[ "${release}" == "alpine" ]]; then
        append_cron_line "0 $cronhr * * * $(get_restart_command)"
      else
        append_cron_line "0 $cronhr * * * root $(get_restart_command)"
      fi
      echo -e "定时重启设置成功！"
    fi
  elif [ "$numcron" == "2" ]; then
    sed -i "/gost/d" "$(get_cron_file)"
    echo -e "定时重启任务删除完成！"
  fi
}

update_sh() {
  local ol_version=""
  local script_path=""
  local temp_script=""
  local -a forward_args=("$@")
  script_path="${BASH_SOURCE[0]}"
  [[ "${script_path}" != /* ]] && script_path="$(pwd)/${script_path}"
  if command -v curl >/dev/null 2>&1; then
    ol_version=$(curl -L -s --connect-timeout 5 https://raw.githubusercontent.com/YeJianbo/Multi-EasyGost/v2/gost.sh | grep "shell_version=" | head -1 | awk -F '=|"' '{print $3}')
  elif command -v wget >/dev/null 2>&1; then
    ol_version=$(wget --no-check-certificate -qO- -t2 -T3 https://raw.githubusercontent.com/YeJianbo/Multi-EasyGost/v2/gost.sh | grep "shell_version=" | head -1 | awk -F '=|"' '{print $3}')
  fi
  if [ -n "$ol_version" ]; then
    if [[ "$shell_version" != "$ol_version" ]]; then
      echo -e "${Info} 检测到新版本，正在自动更新脚本..."
      temp_script=$(make_temp_file "gost-update" ".sh") || {
        echo -e "${Error} 无法创建更新临时文件。"
        return 1
      }
      if ! download_file "https://raw.githubusercontent.com/YeJianbo/Multi-EasyGost/v2/gost.sh" "${temp_script}"; then
        rm -f "${temp_script}"
        echo -e "${Error} 自动更新失败，请检查网络。"
        return 1
      fi
      if ! bash -n "${temp_script}" >/dev/null 2>&1; then
        rm -f "${temp_script}"
        echo -e "${Error} 下载到的新脚本语法检查失败，已取消自动更新。"
        return 1
      fi
      chmod +x "${temp_script}"
      mv "${temp_script}" "${script_path}"
      chmod +x "${script_path}"
      echo -e "${Info} 脚本已自动更新，正在重载。"
      exec bash "${script_path}" "${forward_args[@]}"
    fi
  fi
}

show_main_menu() {
  echo && echo -e "                 gost 一键安装配置脚本"${Red_font_prefix}[${shell_version}]${Font_color_suffix}"
  ----------- YeJianbo -----------
  特性: (1)本脚本采用systemd及gost配置文件对gost进行管理
        (2)能够在不借助其他工具(如screen)的情况下实现多条转发规则同时生效
        (3)机器reboot后转发不失效
  功能: (1)tcp+udp不加密转发, (2)中转机加密转发, (3)落地机解密对接转发
  帮助文档：https://github.com/YeJianbo/Multi-EasyGost

 ${Green_font_prefix}1.${Font_color_suffix} 安装 gost
 ${Green_font_prefix}2.${Font_color_suffix} 更新 gost
 ${Green_font_prefix}3.${Font_color_suffix} 卸载 gost
————————————
 ${Green_font_prefix}4.${Font_color_suffix} 启动 gost
 ${Green_font_prefix}5.${Font_color_suffix} 停止 gost
 ${Green_font_prefix}6.${Font_color_suffix} 重启 gost
————————————
 ${Green_font_prefix}7.${Font_color_suffix} 新增gost转发配置
 ${Green_font_prefix}8.${Font_color_suffix} 查看现有gost配置
 ${Green_font_prefix}9.${Font_color_suffix} 删除一则gost配置
————————————
 ${Green_font_prefix}10.${Font_color_suffix} gost定时重启配置
 ${Green_font_prefix}11.${Font_color_suffix} 自定义TLS证书配置
 ${Green_font_prefix}12.${Font_color_suffix} 导出分享码
 ${Green_font_prefix}13.${Font_color_suffix} 导入分享码
————————————" && echo
}

handle_main_menu() {
  local num=""
  prompt_choice " 请输入数字 [1-13]:" 1 2 3 4 5 6 7 8 9 10 11 12 13
  num="$REPLY"
  case "$num" in
1)
  Install_ct
  ;;
2)
  checknew
  ;;
3)
  Uninstall_ct
  ;;
4)
  Start_ct
  ;;
5)
  Stop_ct
  ;;
6)
  Restart_ct
  ;;
7)
  if ! is_gost_installed; then
    echo -e "${Error} gost 尚未安装，请先安装。"
    return 0
  fi
  rawconf
  if apply_runtime_config; then
    echo -e "配置已生效，当前配置如下"
    echo -e "--------------------------------------------------------"
    show_all_conf
  fi
  ;;
8)
  show_all_conf
  ;;
9)
  if ! is_gost_installed; then
    echo -e "${Error} gost 尚未安装，请先安装。"
    return 0
  fi
  show_all_conf
  if [[ ! -s "$raw_conf_path" ]]; then
    return 0
  fi
  count_line=$(awk 'END{print NR}' "$raw_conf_path")
  while true; do
    prompt_nonempty "请输入你要删除的配置编号：" validate_menu_number "请输入正确数字"
    numdelete="$REPLY"
    if ((10#$numdelete >= 1 && 10#$numdelete <= count_line)); then
      break
    fi
    echo "编号超出范围，请输入 1-${count_line}"
  done
  sed -i "${numdelete}d" "$raw_conf_path"
  if apply_runtime_config; then
    echo -e "配置已删除，服务已重启"
  fi
  ;;
10)
  cron_restart
  ;;
11)
  cert
  ;;
12)
  export_share_code
  ;;
13)
  import_share_code
  ;;
*)
  echo "请输入正确数字 [1-13]"
  ;;
  esac
  pause_before_menu
}

process_cli_args() {
  local share_code=""
  local import_mode="overwrite"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --import-share-code)
      [[ $# -ge 2 ]] || {
        echo -e "${Error} --import-share-code 缺少参数。"
        return 1
      }
      share_code="$2"
      shift 2
      ;;
    --import-mode)
      [[ $# -ge 2 ]] || {
        echo -e "${Error} --import-mode 缺少参数。"
        return 1
      }
      import_mode="$2"
      shift 2
      ;;
    *)
      echo -e "${Error} 不支持的参数：$1"
      return 1
      ;;
    esac
  done

  if [[ -n "${share_code}" ]]; then
    check_root
    check_sys
    if ! is_gost_installed; then
      echo -e "${Info} 检测到 gost 尚未安装，正在自动安装..."
      if ! Install_ct; then
        echo -e "${Error} gost 自动安装失败。"
        return 1
      fi
    fi
    import_share_code_value "${share_code}" "${import_mode}"
    return $?
  fi

  return 2
}

main() {
  if process_cli_args "$@"; then
    return 0
  else
    local cli_status=$?
    if [[ ${cli_status} -ne 2 ]]; then
      return ${cli_status}
    fi
  fi

  update_sh "$@"
  while true; do
    show_main_menu
    handle_main_menu
  done
}

main "$@"

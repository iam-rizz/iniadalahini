#!/bin/bash
#
# lxc-iolimit installer
# IO limit disk (cgroup v2 io.max) per plan untuk LXC di Proxmox VE + Virtualizor
#
# Usage:
#   bash install.sh             install / update
#   bash install.sh uninstall   hapus (config di /etc/lxc-iolimit tetap disimpan)
#   bash install.sh purge       hapus beserta config
#

VERSION="1.0.0"

APP_DIR=/usr/local/lxc-iolimit
CONF_DIR=/etc/lxc-iolimit
BIN=$APP_DIR/lxc-iolimit
HOOK=$APP_DIR/lxc-hook.sh
VIRT_INC=$APP_DIR/virtualizor-filter.php
LXC_CONF_DIR=/usr/share/lxc/config/common.conf.d
LXC_HOOK_CONF=$LXC_CONF_DIR/99-lxc-iolimit.conf
LOGROTATE=/etc/logrotate.d/lxc-iolimit
VIRT_HOOKS=/usr/local/virtualizor/hooks
FILTER=$VIRT_HOOKS/filter.php
OLD_SNIP=/var/lib/vz/snippets

MARK_BEGIN='// >>> lxc-iolimit BEGIN (dikelola install.sh, jangan diedit)'
MARK_END='// <<< lxc-iolimit END'
MARK_LINE='// lxc-iolimit'

info(){ echo -e "\e[32m[+]\e[0m $*"; }
warn(){ echo -e "\e[33m[!]\e[0m $*"; }
die(){  echo -e "\e[31m[x]\e[0m $*"; exit 1; }

php_bin(){
  if [ -x /usr/local/emps/bin/php ]; then echo /usr/local/emps/bin/php; else command -v php; fi
}

php_lint(){
  local p; p=$(php_bin)
  if [ -z "$p" ]; then warn "PHP tidak ditemukan, lint $1 dilewati"; return 0; fi
  "$p" -l "$1" >/dev/null 2>&1
}

need_root(){ [ "$(id -u)" = 0 ] || die "Jalankan sebagai root"; }

# ---------------------------------------------------------------------------
# Pengecekan awal
# ---------------------------------------------------------------------------
preflight(){
  need_root
  command -v pct >/dev/null   || die "pct tidak ditemukan. Script ini untuk node Proxmox VE."
  command -v pvesm >/dev/null || die "pvesm tidak ditemukan. Script ini untuk node Proxmox VE."
  [ -f /sys/fs/cgroup/cgroup.controllers ] || die "cgroup v2 tidak aktif."
  grep -qw io /sys/fs/cgroup/cgroup.controllers || die "Controller 'io' cgroup v2 tidak tersedia."
  [ -d "$LXC_CONF_DIR" ] || die "$LXC_CONF_DIR tidak ditemukan."

  # Setup manual lama (fungsi iolimit_* langsung di filter.php) harus dihapus dulu,
  # supaya tidak bentrok dengan versi ini.
  if [ -f "$FILTER" ]; then
    local old
    old=$(grep -nE "function[[:space:]]+iolimit_|'iolimit_" "$FILTER")
    if [ -n "$old" ]; then
      echo "$old"
      die "Ditemukan kode IO limit lama (iolimit_*) di $FILTER.
    Hapus fungsi/insert_filter di baris di atas (lihat README bagian Migrasi), lalu jalankan ulang installer."
    fi
  fi
}

# ---------------------------------------------------------------------------
# File aplikasi
# ---------------------------------------------------------------------------
write_cli(){
  mkdir -p "$APP_DIR"
  cat > "$BIN" << 'EOF'
#!/bin/bash
# lxc-iolimit - IO limit disk (cgroup v2 io.max) untuk LXC Proxmox
export LC_ALL=C

CONF_DIR=/etc/lxc-iolimit
MAP=$CONF_DIR/ct.map
PLANS=$CONF_DIR/plans.conf
LOG=/var/log/lxc-iolimit.log
MB=1048576

log(){ echo "$(date -Is) $*" >> "$LOG"; }

usage(){
cat << USAGE
Usage: lxc-iolimit <command> [args]

  apply <ctid>        Terapkan limit ke CT (sesuai ct.map / plans.conf)
  apply-all           Terapkan limit ke semua CT yang running
  set <ctid> <MB/s>   Set limit manual untuk CT (0 = tanpa limit)
  plan <ctid> <plid>  Set CT memakai limit plan tertentu
  unset <ctid>        Hapus CT dari ct.map (kembali ke default)
  clear <ctid>        Lepas limit di cgroup (sementara, sampai CT start lagi)
  clear-all           Lepas limit semua CT yang running
  status              Tampilkan limit semua CT yang running
USAGE
exit 1
}

is_num(){ [[ "$1" =~ ^[0-9]+$ ]]; }

# MB/s untuk plan id (atau "default")
plan_mb(){
  local v
  v=$(awk -F= -v k="$1" '{gsub(/[ \t\r]/,"")} $1==k{v=$2} END{print v}' "$PLANS" 2>/dev/null)
  if is_num "$v"; then echo "$v"
  elif [ "$1" != default ]; then plan_mb default
  else echo 100
  fi
}

# Nilai mentah ct.map untuk CT
ct_entry(){ awk -F= -v id="$1" '$1==id{v=$2} END{print v}' "$MAP" 2>/dev/null; }

# MB/s untuk CT
ct_mb(){
  local v; v=$(ct_entry "$1")
  case "$v" in
    plan:*) plan_mb "${v#plan:}" ;;
    '')     plan_mb default ;;
    *)      if is_num "$v"; then echo "$v"; else plan_mb default; fi ;;
  esac
}

ct_dev(){
  local vol path
  vol=$(awk -F'[ ,]' '/^rootfs:/{print $2; exit}' "/etc/pve/lxc/$1.conf" 2>/dev/null)
  [ -n "$vol" ] || return 1
  path=$(pvesm path "$vol" 2>/dev/null) || return 1
  [ -b "$path" ] || return 1
  lsblk -dno MAJ:MIN "$path" 2>/dev/null | tr -d ' '
}

wait_cg(){
  local i
  for i in $(seq 1 30); do
    [ -f "/sys/fs/cgroup/lxc/$1/io.max" ] && return 0
    sleep 1
  done
  return 1
}

# write_limit <ctid> <MB/s, 0 = max>
write_limit(){
  local id=$1 mb=$2 dev val
  wait_cg "$id" || { log "CT $id GAGAL: cgroup /sys/fs/cgroup/lxc/$id tidak ditemukan"; return 1; }
  dev=$(ct_dev "$id")
  [ -n "$dev" ] || { log "CT $id GAGAL: device rootfs tidak ditemukan"; return 1; }
  if [ "$mb" -gt 0 ]; then
    val="rbps=$((mb * MB)) wbps=$((mb * MB))"
  else
    val="rbps=max wbps=max"
  fi
  if echo "$dev $val" > "/sys/fs/cgroup/lxc/$id/io.max" 2>/dev/null; then
    log "CT $id $dev $val OK"
  else
    log "CT $id $dev GAGAL menulis io.max ($val)"
    return 1
  fi
}

map_set(){   # map_set <ctid> <value|"">
  mkdir -p "$CONF_DIR"; touch "$MAP"
  sed -i "/^$1=/d" "$MAP"
  [ -n "$2" ] && echo "$1=$2" >> "$MAP"
  return 0
}

running(){ pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}'; }
is_running(){ [ -f "/sys/fs/cgroup/lxc/$1/io.max" ]; }
human(){ if [ "$1" -gt 0 ] 2>/dev/null; then echo "$1 MB/s"; else echo "unlimited"; fi; }

case "${1:-}" in
  apply)
    is_num "${2:-}" || usage
    write_limit "$2" "$(ct_mb "$2")" ;;
  apply-all)
    for id in $(running); do
      if write_limit "$id" "$(ct_mb "$id")"; then echo "CT $id: $(human "$(ct_mb "$id")")"
      else echo "CT $id: GAGAL (lihat $LOG)"; fi
    done ;;
  set)
    is_num "${2:-}" && is_num "${3:-}" || usage
    map_set "$2" "$3"
    echo "CT $2: $(human "$3")"
    if is_running "$2"; then write_limit "$2" "$3"; fi ;;
  plan)
    is_num "${2:-}" && is_num "${3:-}" || usage
    map_set "$2" "plan:$3"
    echo "CT $2: plan $3 ($(human "$(plan_mb "$3")"))"
    if is_running "$2"; then write_limit "$2" "$(ct_mb "$2")"; fi ;;
  unset)
    is_num "${2:-}" || usage
    map_set "$2" ""
    echo "CT $2: default ($(human "$(plan_mb default)"))"
    if is_running "$2"; then write_limit "$2" "$(ct_mb "$2")"; fi ;;
  clear)
    is_num "${2:-}" || usage
    write_limit "$2" 0 ;;
  clear-all)
    for id in $(running); do write_limit "$id" 0; done ;;
  status)
    printf "%-7s %-10s %-14s %s\n" "CT" "SUMBER" "LIMIT" "IO.MAX"
    for id in $(running); do
      src=$(ct_entry "$id"); src=${src:-default}
      is_num "$src" && src="manual"
      printf "%-7s %-10s %-14s %s\n" "$id" "$src" "$(human "$(ct_mb "$id")")" \
        "$(tr '\n' ' ' < "/sys/fs/cgroup/lxc/$id/io.max" 2>/dev/null)"
    done ;;
  *) usage ;;
esac
EOF
  chmod 755 "$BIN"
  ln -sf "$BIN" /usr/local/bin/lxc-iolimit
}

write_hook(){
  cat > "$HOOK" << 'EOF'
#!/bin/bash
# lxc-iolimit: LXC start-host hook (global, berlaku untuk semua CT).
# Dijalankan di background dan HARUS exit 0, kalau tidak CT gagal start.
if [ -n "$LXC_NAME" ]; then
  setsid nohup /usr/local/lxc-iolimit/lxc-iolimit apply "$LXC_NAME" >/dev/null 2>&1 < /dev/null &
fi
exit 0
EOF
  chmod 755 "$HOOK"
}

write_virt_inc(){
  cat > "$VIRT_INC" << 'EOF'
<?php
/**
 * lxc-iolimit - integrasi Virtualizor
 * Di-include dari /usr/local/virtualizor/hooks/filter.php oleh install.sh
 */
if(!defined('VIRTUALIZOR')){
	die('Hacking Attempt');
}

if(!defined('LXC_IOLIMIT_MAP')){
	define('LXC_IOLIMIT_MAP', '/etc/lxc-iolimit/ct.map');
	define('LXC_IOLIMIT_BIN', '/usr/local/lxc-iolimit/lxc-iolimit');
	define('LXC_IOLIMIT_LOG', '/var/log/lxc-iolimit.log');
}

function lxc_iolimit_log($msg){
	@file_put_contents(LXC_IOLIMIT_LOG, date('c').' '.$msg."\n", FILE_APPEND);
}

// Hanya LXC di Proxmox (virt = proxl)
function lxc_iolimit_is_lxc($vps){
	return empty($vps['virt']) || $vps['virt'] === 'proxl';
}

// Set / hapus (value = null) entri CT di ct.map
function lxc_iolimit_map_set($ctid, $value){
	$lines = array();
	if(file_exists(LXC_IOLIMIT_MAP)){
		foreach(file(LXC_IOLIMIT_MAP, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $l){
			if(strpos($l, $ctid.'=') !== 0){
				$lines[] = $l;
			}
		}
	}
	if($value !== null){
		$lines[] = $ctid.'='.$value;
	}
	@file_put_contents(LXC_IOLIMIT_MAP, implode("\n", $lines).(count($lines) ? "\n" : ''), LOCK_EX);
}

// Catat plan CT ke ct.map, lalu terapkan langsung kalau CT sedang running
function lxc_iolimit_apply($ctid, $plid){
	$ctid = (int)$ctid;
	$plid = (int)$plid;
	if($ctid <= 0){
		return;
	}
	lxc_iolimit_map_set($ctid, 'plan:'.$plid);
	lxc_iolimit_log("CT $ctid plan $plid");
	if(file_exists("/sys/fs/cgroup/lxc/$ctid/io.max")){
		@exec(escapeshellarg(LXC_IOLIMIT_BIN).' apply '.$ctid.' >/dev/null 2>&1');
	}
}

function lxc_iolimit_unsuspend($vpsid){
	if(!function_exists('getvps')){
		return;
	}
	$vps = getvps($vpsid);
	if(empty($vps['vps_name']) || !lxc_iolimit_is_lxc($vps)){
		return;
	}
	lxc_iolimit_apply($vps['vps_name'], $vps['plid']);
}

// VM baru (juga terpanggil saat edit VM)
insert_filter('after_createvps', 'lxc_iolimit_after_createvps', 1, 1);
function lxc_iolimit_after_createvps($vps){
	if(!lxc_iolimit_is_lxc($vps)){
		return;
	}
	lxc_iolimit_apply($vps['vps_name'], $vps['plid']);
}

// Edit VM / upgrade / downgrade plan
insert_filter('editvs', 'lxc_iolimit_editvs', 1, 2);
function lxc_iolimit_editvs($vps, $editvs){
	if(!lxc_iolimit_is_lxc($vps)){
		return;
	}
	$plid = (isset($editvs['plid']) && $editvs['plid'] !== '') ? $editvs['plid'] : $vps['plid'];
	lxc_iolimit_apply($vps['vps_name'], $plid);
}

// VM dihapus: bersihkan ct.map
insert_filter('after_deletevps', 'lxc_iolimit_after_deletevps', 1, 1);
function lxc_iolimit_after_deletevps($vps){
	if(empty($vps['vps_name']) || !lxc_iolimit_is_lxc($vps)){
		return;
	}
	lxc_iolimit_map_set((int)$vps['vps_name'], null);
	lxc_iolimit_log('CT '.(int)$vps['vps_name'].' dihapus dari map');
}

// Unsuspend: kalau filter.php sudah punya my_unsuspendvps, install.sh menyisipkan
// pemanggilan lxc_iolimit_unsuspend() di dalamnya. Kalau tidak ada, daftarkan sendiri.
if(!function_exists('my_unsuspendvps')){
	insert_filter('unsuspendvps', 'lxc_iolimit_unsuspendvps', 1, 1);
	function lxc_iolimit_unsuspendvps($vpsid){
		lxc_iolimit_unsuspend($vpsid);
		return true;
	}
}
EOF
  chmod 644 "$VIRT_INC"
  php_lint "$VIRT_INC" || die "Syntax error di $VIRT_INC"
}

write_config(){
  mkdir -p "$CONF_DIR"
  if [ ! -f "$CONF_DIR/plans.conf" ]; then
    cat > "$CONF_DIR/plans.conf" << 'EOF'
# lxc-iolimit: limit IO disk per plan Virtualizor (MB/s, berlaku untuk read & write)
#
# Format : <plan_id>=<MB/s>     (0 = tanpa limit)
# default: dipakai untuk CT yang tidak ada di ct.map atau plan yang tidak terdaftar
#
# Plan ID lihat di Virtualizor: Plans > List Plans (kolom ID)
# Setelah mengubah file ini jalankan: lxc-iolimit apply-all

default=100
1=100
2=200
EOF
    info "Config dibuat: $CONF_DIR/plans.conf (sesuaikan dengan plan Anda)"
  else
    info "Config lama dipertahankan: $CONF_DIR/plans.conf"
  fi
  touch "$CONF_DIR/ct.map"

  cat > "$LOGROTATE" << 'EOF'
/var/log/lxc-iolimit.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF
}

install_lxc_hook(){
  echo "lxc.hook.start-host = $HOOK" > "$LXC_HOOK_CONF"
  info "Hook LXC global: $LXC_HOOK_CONF"
}

# ---------------------------------------------------------------------------
# Migrasi dari setup manual lama (snippets + hookscript per CT)
# ---------------------------------------------------------------------------
migrate_old(){
  local f id v

  if [ -f "$OLD_SNIP/iolimit.map" ]; then
    while IFS='=' read -r id v; do
      [[ "$id" =~ ^[0-9]+$ && "$v" =~ ^[0-9]+$ ]] || continue
      grep -q "^$id=" "$CONF_DIR/ct.map" || echo "$id=$((v / 1048576))" >> "$CONF_DIR/ct.map"
    done < "$OLD_SNIP/iolimit.map"
    info "Map lama dimigrasi dari $OLD_SNIP/iolimit.map (nilai lama jadi limit manual MB/s)"
  fi

  for f in /etc/pve/lxc/*.conf; do
    [ -e "$f" ] || continue
    if grep -q '^hookscript: local:snippets/iolimit.sh' "$f"; then
      id=$(basename "$f" .conf)
      if pct set "$id" --delete hookscript >/dev/null 2>&1; then
        info "CT $id: hookscript lama dilepas"
      else
        warn "CT $id: gagal melepas hookscript lama. Jalankan manual: pct set $id --delete hookscript"
      fi
    fi
  done

  if [ -f "$LXC_CONF_DIR/99-iolimit.conf" ] && grep -q 'snippets/iolimit' "$LXC_CONF_DIR/99-iolimit.conf"; then
    rm -f "$LXC_CONF_DIR/99-iolimit.conf"
    info "Hook LXC global lama dihapus ($LXC_CONF_DIR/99-iolimit.conf)"
  fi
}

# ---------------------------------------------------------------------------
# Integrasi Virtualizor (filter.php)
# ---------------------------------------------------------------------------
install_virtualizor(){
  if [ ! -d "$VIRT_HOOKS" ]; then
    warn "Virtualizor tidak ditemukan ($VIRT_HOOKS). Integrasi Virtualizor dilewati."
    return 0
  fi

  if [ ! -f "$FILTER" ]; then
    if [ ! -f "$VIRT_HOOKS/filter.txt" ]; then
      warn "$VIRT_HOOKS/filter.txt tidak ada. Integrasi Virtualizor dilewati."
      return 0
    fi
    cp "$VIRT_HOOKS/filter.txt" "$FILTER"
    info "filter.php dibuat dari filter.txt"
  fi

  if tail -n 3 "$FILTER" | grep -qE '^[[:space:]]*\?>[[:space:]]*$'; then
    warn "filter.php diakhiri '?>'. Hapus baris itu lalu jalankan ulang installer."
    return 0
  fi

  local bak; bak="$FILTER.bak-$(date +%Y%m%d%H%M%S)"
  cp -p "$FILTER" "$bak"

  if ! grep -qF "$MARK_BEGIN" "$FILTER"; then
    cat >> "$FILTER" << EOF

$MARK_BEGIN
if(file_exists('$VIRT_INC')){
	include_once '$VIRT_INC';
}
$MARK_END
EOF
  fi

  local unsusp="	if(function_exists('lxc_iolimit_unsuspend')) lxc_iolimit_unsuspend(\$vpsid); $MARK_LINE"
  if grep -qE 'function[[:space:]]+my_unsuspendvps' "$FILTER" \
     && ! grep -qF "lxc_iolimit_unsuspend(\$vpsid); $MARK_LINE" "$FILTER"; then
    awk -v ins="$unsusp" '
      { print }
      !done && /function[ \t]+my_unsuspendvps[ \t]*\([ \t]*\$vpsid[ \t]*\)[ \t]*\{/ { print ins; done=1 }
    ' "$FILTER" > "$FILTER.tmp" && cat "$FILTER.tmp" > "$FILTER"
    rm -f "$FILTER.tmp"
    if ! grep -qF "lxc_iolimit_unsuspend(\$vpsid); $MARK_LINE" "$FILTER"; then
      warn "Tidak bisa menyisipkan hook unsuspend ke my_unsuspendvps(). Tambahkan manual (lihat README)."
    fi
  fi

  if php_lint "$FILTER"; then
    info "filter.php terpasang (backup: $bak)"
  else
    cp -p "$bak" "$FILTER"
    die "Syntax error setelah edit filter.php. File dikembalikan dari backup: $bak"
  fi
}

# ---------------------------------------------------------------------------
do_install(){
  echo "lxc-iolimit installer v$VERSION"
  preflight
  write_config
  write_cli
  write_hook
  write_virt_inc
  migrate_old
  install_lxc_hook
  install_virtualizor

  info "Menerapkan limit ke CT yang running..."
  "$BIN" apply-all

  echo
  info "Selesai. Cek status: lxc-iolimit status"
  info "Log: /var/log/lxc-iolimit.log"
}

do_uninstall(){
  need_root
  [ -x "$BIN" ] && { info "Melepas limit dari CT yang running..."; "$BIN" clear-all; }

  rm -f "$LXC_HOOK_CONF"

  if [ -f "$FILTER" ]; then
    local bak; bak="$FILTER.bak-$(date +%Y%m%d%H%M%S)"
    cp -p "$FILTER" "$bak"
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" -v m="$MARK_LINE" '
      index($0, b) { skip=1 }
      !skip && index($0, "lxc_iolimit_unsuspend(") && index($0, m) { next }
      !skip { print }
      index($0, e) { skip=0 }
    ' "$FILTER" > "$FILTER.tmp" && cat "$FILTER.tmp" > "$FILTER"
    rm -f "$FILTER.tmp"
    if php_lint "$FILTER"; then
      info "Integrasi dihapus dari filter.php (backup: $bak)"
    else
      cp -p "$bak" "$FILTER"
      warn "Syntax error setelah edit filter.php, dikembalikan dari backup. Hapus blok lxc-iolimit manual."
    fi
  fi

  rm -rf "$APP_DIR"
  rm -f /usr/local/bin/lxc-iolimit "$LOGROTATE"

  if [ "$1" = purge ]; then
    rm -rf "$CONF_DIR"
    info "Config $CONF_DIR dihapus"
  else
    info "Config disimpan di $CONF_DIR (hapus dengan: bash install.sh purge)"
  fi
  info "Uninstall selesai"
}

case "${1:-install}" in
  install)   do_install ;;
  uninstall) do_uninstall ;;
  purge)     do_uninstall purge ;;
  *) echo "Usage: bash install.sh [install|uninstall|purge]"; exit 1 ;;
esac

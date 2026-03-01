#!/system/bin/sh

box_dir="/data/adb/box"
box_run="${box_dir}/run"
box_pid="${box_run}/box.pid"
MODPATH="${0%/*}"

while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 1
done

resetprop_if_diff() {
    key="$1"
    desired="$2"
    current="$(resetprop "$key")"
    [ -z "$current" ] || [ "$current" = "$desired" ] || resetprop "$key" "$desired"
}

for k in \
    ro.lineage.build.version \
    ro.lineage.build.version.plat.rev \
    ro.lineage.build.version.plat.sdk \
    ro.lineage.device \
    ro.lineage.display.version \
    ro.lineage.releasetype \
    ro.lineage.version \
    ro.lineagelegal.url
do
    resetprop --delete "$k"
done

resetprop | awk -F '\\[|\\]: \\[|\\]' '/lineage/ { print $2 }' | while read -r key; do
    [ -n "$key" ] && resetprop --delete "$key"
done

resetprop | awk -F '\\[|\\]: \\[|\\]' '
{
    key=$2
    value=$3
    if (value ~ /userdebug/ || value ~ /test-keys/ || value ~ /lineage_/) {
        gsub("userdebug", "user", value)
        gsub("test-keys", "release-keys", value)
        gsub("lineage_?", "", value)
        printf("%s=%s\n", key, value)
    }
}' | while IFS="=" read -r key value; do
    resetprop "$key" "$value"
done

resetprop_if_diff ro.boot.flash.locked 1
resetprop_if_diff ro.boot.vbmeta.device_state locked
resetprop_if_diff ro.boot.verifiedbootstate green
resetprop_if_diff ro.boot.veritymode enforcing
resetprop_if_diff vendor.boot.verifiedbootstate green
resetprop_if_diff vendor.boot.vbmeta.device_state locked

resetprop_if_diff ro.boot.warranty_bit 0
resetprop_if_diff ro.boot.bootreason normal

resetprop_if_diff ro.is_everrooted false
resetprop_if_diff ro.boot.is_charger false

run_as_su() {
    su -c "$1"
}

stop_service() {
    echo "服务正在关闭..."
    run_as_su "${box_dir}/scripts/box.iptables disable"
    run_as_su "${box_dir}/scripts/box.service stop"
}

start_service() {
    echo "服务正在启动，请稍候..."
    run_as_su "${box_dir}/scripts/box.service start"
    run_as_su "${box_dir}/scripts/box.iptables enable"
}

if [ -f "${box_pid}" ]; then
    PID=$(cat "${box_pid}")
    if [ -e "/proc/${PID}" ]; then
        stop_service
    else
        start_service
    fi
else
    start_service
fi

exit 0
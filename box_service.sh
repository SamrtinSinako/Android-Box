#!/system/bin/sh

(
    until [ $(getprop init.svc.bootanim) = "stopped" ]; do
        sleep 10
    done

    if [ -f "/data/adb/box/scripts/start.sh" ]; then
        chmod 755 /data/adb/box/scripts/*
        /data/adb/box/scripts/start.sh
        SCRIPTS_DIR="/data/adb/box/scripts"

        while [ ! -f /data/misc/net/rt_tables ]; do
            sleep 3
        done
        inotifyd ${SCRIPTS_DIR}/ctr.inotify /data/misc/net/rt_tables > /dev/null 2>&1 &
    else
        echo "未找到文件 '/data/adb/box/scripts/start.sh'"
    fi
)&

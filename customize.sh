#!/system/bin/sh

SKIPUNZIP=1
SKIPMOUNT=false
PROPFILE=true
POSTFSDATA=false
LATESTARTSERVICE=true

if [ "$BOOTMODE" != true ]; then
  abort "-----------------------------------------------------------"
  ui_print "! 请在 Magisk/KernelSU/APatch Manager 中安装本模块"
  ui_print "! 不支持从 Recovery 安装"
  abort "-----------------------------------------------------------"
elif [ "$KSU" = "true" ] && [ "$KSU_VER_CODE" -lt 10670 ]; then
  abort "-----------------------------------------------------------"
  ui_print "! 请升级您的 KernelSU 及其管理器"
  abort "-----------------------------------------------------------"
fi

service_dir="/data/adb/service.d"
if [ "$KSU" = "true" ]; then
  ui_print "- 检测到 KernelSU 版本: $KSU_VER ($KSU_VER_CODE)"
  [ "$KSU_VER_CODE" -lt 10683 ] && service_dir="/data/adb/ksu/service.d"
elif [ "$APATCH" = "true" ]; then
  APATCH_VER=$(cat "/data/adb/ap/version")
  ui_print "- 检测到 APatch 版本: $APATCH_VER"
else
  ui_print "- 检测到 Magisk 版本: $MAGISK_VER ($MAGISK_VER_CODE)"
fi

mkdir -p "${service_dir}"
if [ -d "/data/adb/modules/box_for_magisk" ]; then
  rm -rf "/data/adb/modules/box_for_magisk"
  ui_print "- 已删除旧模块"
fi

ui_print "- 正在安装 SingBox Pure"
unzip -o "$ZIPFILE" -x 'META-INF/*' -x 'webroot/*' -d "$MODPATH" >&2
if [ -d "/data/adb/box" ]; then
  ui_print "- 备份现有 box 数据"
  temp_bak=$(mktemp -d -p "/data/adb/box" box.XXXXXXXXXX)
  temp_dir="${temp_bak}"
  mv /data/adb/box/* "${temp_dir}/"
  mv "$MODPATH/box/"* /data/adb/box/
  backup_box="true"
else
  mv "$MODPATH/box" /data/adb/
fi

ui_print "- 创建目录"
mkdir -p /data/adb/box/ /data/adb/box/run/ /data/adb/box/bin/

ui_print "- 提取 uninstall.sh 和 box_service.sh"
unzip -j -o "$ZIPFILE" 'uninstall.sh' -d "$MODPATH" >&2
unzip -j -o "$ZIPFILE" 'box_service.sh' -d "${service_dir}" >&2

ui_print "- 设置权限"
set_perm_recursive $MODPATH 0 0 0755 0644
set_perm_recursive /data/adb/box/ 0 3005 0755 0644
set_perm_recursive /data/adb/box/scripts/ 0 3005 0755 0700
set_perm ${service_dir}/box_service.sh 0 0 0755
set_perm $MODPATH/uninstall.sh 0 0 0755
chmod ugo+x ${service_dir}/box_service.sh $MODPATH/uninstall.sh /data/adb/box/scripts/*

if [ "${backup_box}" = "true" ]; then
  ui_print " "
  ui_print "- 正在恢复用户配置和数据..."

  if [ -f "${temp_dir}/settings.ini" ]; then
    if [ -f "/data/adb/box/settings.ini" ]; then
      mv /data/adb/box/settings.ini /data/adb/box/settings.ini.new
      grep -E '^[a-zA-Z0-9_]+=' "${temp_dir}/settings.ini" | while IFS='=' read -r key value; do
        [ -z "${key}" ] && continue
        if grep -q -E "^${key}=" "/data/adb/box/settings.ini.new"; then
          escaped_value=$(printf '%s' "${value}" | sed -e 's/[&\\#]/\\&/g')
          sed -i "s#^${key}=.*#${key}=${escaped_value}#" "/data/adb/box/settings.ini.new"
        fi
      done
      mv /data/adb/box/settings.ini.new /data/adb/box/settings.ini
      ui_print "  - 已合并旧版 settings.ini 配置"
    else
      cp -f "${temp_dir}/settings.ini" "/data/adb/box/settings.ini"
      ui_print "  - 已恢复 settings.ini"
    fi
  fi

  if [ -d "${temp_dir}/sing-box" ]; then
    ui_print "  - 恢复 sing-box 目录配置"
    cp -af "${temp_dir}/sing-box/." "/data/adb/box/sing-box/"
  fi

  ui_print "  - 恢复根目录配置文件"
  for conf_file in ap.list.cfg package.list.cfg crontab.cfg; do
    [ -f "${temp_dir}/${conf_file}" ] && cp -f "${temp_dir}/${conf_file}" "/data/adb/box/${conf_file}"
  done

  if [ -d "${temp_dir}/run" ]; then
    ui_print "  - 恢复运行时文件"
    cp -af "${temp_dir}/run/." "/data/adb/box/run/"
  fi

  ui_print "- 清理备份文件"
  rm -rf "${temp_dir}"
fi

sed -i "s/name=.*/name=SingBox Pure/g" $MODPATH/module.prop

unzip -o "$ZIPFILE" 'webroot/*' -d "$MODPATH" >&2

ui_print "- 清理残留文件"
rm -rf /data/adb/box/bin/.bin $MODPATH/box $MODPATH/box_service.sh

ui_print "- SingBox Pure 安装完成，请重启设备"

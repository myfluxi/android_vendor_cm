#!/bin/bash
#
# Copyright (C) 2016 The CyanogenMod Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

PRODUCT_COPY_FILES_LIST=()
PRODUCT_COPY_FILES_HASHES=()
PRODUCT_PACKAGES_LIST=()
PRODUCT_PACKAGES_HASHES=()
PACKAGE_LIST=()
VENDOR_STATE=-1
VENDOR_RADIO_STATE=-1
COMMON=-1
ARCHES=
FULLY_DEODEXED=-1

TMPDIR="/tmp/extractfiles.$$"
mkdir "$TMPDIR"

#
# cleanup
#
# kill our tmpfiles with fire on exit
#
function cleanup() {
    rm -rf "${TMPDIR:?}"
}

trap cleanup EXIT INT TERM ERR

#
# setup_vendor
#
# $1: device name
# $2: vendor name
# $3: CM root directory
# $4: is common device - optional, default to false
# $5: cleanup - optional, default to true
# $6: custom vendor makefile name - optional, default to false
#
# Must be called before any other functions can be used. This
# sets up the internal state for a new vendor configuration.
#
function setup_vendor() {
    local DEVICE="$1"
    if [ -z "$DEVICE" ]; then
        echo "\$DEVICE must be set before including this script!"
        exit 1
    fi

    export VENDOR="$2"
    if [ -z "$VENDOR" ]; then
        echo "\$VENDOR must be set before including this script!"
        exit 1
    fi

    export CM_ROOT="$3"
    if [ ! -d "$CM_ROOT" ]; then
        echo "\$CM_ROOT must be set and valid before including this script!"
        exit 1
    fi

    export OUTDIR=vendor/"$VENDOR"/"$DEVICE"
    if [ ! -d "$CM_ROOT/$OUTDIR" ]; then
        mkdir -p "$CM_ROOT/$OUTDIR"
    fi

    VNDNAME="$6"
    if [ -z "$VNDNAME" ]; then
        VNDNAME="$DEVICE"
    fi

    export PRODUCTMK="$CM_ROOT"/"$OUTDIR"/"$VNDNAME"-vendor.mk
    export ANDROIDMK="$CM_ROOT"/"$OUTDIR"/Android.mk
    export BOARDMK="$CM_ROOT"/"$OUTDIR"/BoardConfigVendor.mk

    if [ "$4" == "true" ] || [ "$4" == "1" ]; then
        COMMON=1
    else
        COMMON=0
    fi

    if [ "$5" == "true" ] || [ "$5" == "1" ]; then
        VENDOR_STATE=1
        VENDOR_RADIO_STATE=1
    else
        VENDOR_STATE=0
        VENDOR_RADIO_STATE=0
    fi
}

#
# target_file:
#
# $1: colon delimited list
#
# Returns destination filename without args
#
function target_file() {
    local LINE="$1"
    local SPLIT=(${LINE//:/ })
    local COUNT=${#SPLIT[@]}
    if [ "$COUNT" -gt "1" ]; then
        if [[ "${SPLIT[1]}" =~ .*/.* ]]; then
            printf '%s\n' "${SPLIT[1]}"
            return 0
        fi
    fi
    printf '%s\n' "${SPLIT[0]}"
}

#
# target_args:
#
# $1: colon delimited list
#
# Returns optional arguments (last value) for given target
#
function target_args() {
    local LINE="$1"
    local SPLIT=(${LINE//:/ })
    local COUNT=${#SPLIT[@]}
    if [ "$COUNT" -gt "1" ]; then
        if [[ ! "${SPLIT[$COUNT-1]}" =~ .*/.* ]]; then
            printf '%s\n' "${SPLIT[$COUNT-1]}"
        fi
    fi
}

#
# prefix_match:
#
# $1: the prefix to match on
#
# Internal function which loops thru the packages list and returns a new
# list containing the matched files with the prefix stripped away.
#
function prefix_match() {
    local PREFIX="$1"
    for FILE in "${PRODUCT_PACKAGES_LIST[@]}"; do
        if [[ "$FILE" =~ ^"$PREFIX" ]]; then
            printf '%s\n' "${FILE#$PREFIX}"
        fi
    done
}

#
# write_product_copy_files:
#
# Creates the PRODUCT_COPY_FILES section in the product makefile for all
# items in the list which do not start with a dash (-).
#
function write_product_copy_files() {
    local COUNT=${#PRODUCT_COPY_FILES_LIST[@]}
    local TARGET=
    local FILE=
    local LINEEND=

    if [ "$COUNT" -eq "0" ]; then
        return 0
    fi

    printf '%s\n' "PRODUCT_COPY_FILES += \\" >> "$PRODUCTMK"
    for (( i=1; i<COUNT+1; i++ )); do
        FILE="${PRODUCT_COPY_FILES_LIST[$i-1]}"
        LINEEND=" \\"
        if [ "$i" -eq "$COUNT" ]; then
            LINEEND=""
        fi

        TARGET=$(target_file "$FILE")
        printf '    %s/proprietary/%s:system/%s%s\n' \
            "$OUTDIR" "$TARGET" "$TARGET" "$LINEEND" >> "$PRODUCTMK"
    done
    return 0
}

#
# write_packages:
#
# $1: The LOCAL_MODULE_CLASS for the given module list
# $2: "true" if this package is part of the vendor/ path
# $3: type-specific extra flags
# $4: Name of the array holding the target list
#
# Internal function which writes out the BUILD_PREBUILT stanzas
# for all modules in the list. This is called by write_product_packages
# after the modules are categorized.
#
function write_packages() {

    local CLASS="$1"
    local VENDOR_PKG="$2"
    local EXTRA="$3"

    # Yes, this is a horrible hack - we create a new array using indirection
    local ARR_NAME="$4[@]"
    local FILELIST=("${!ARR_NAME}")

    local FILE=
    local ARGS=
    local BASENAME=
    local EXTENSION=
    local PKGNAME=
    local SRC=

    for P in "${FILELIST[@]}"; do
        FILE=$(target_file "$P")
        ARGS=$(target_args "$P")

        BASENAME=$(basename "$FILE")
        EXTENSION=${BASENAME##*.}
        PKGNAME=${BASENAME%.*}

        # Add to final package list
        PACKAGE_LIST+=("$PKGNAME")

        SRC="proprietary"
        if [ "$VENDOR_PKG" = "true" ]; then
            SRC+="/vendor"
        fi

        printf 'include $(CLEAR_VARS)\n'
        printf 'LOCAL_MODULE := %s\n' "$PKGNAME"
        printf 'LOCAL_MODULE_OWNER := %s\n' "$VENDOR"
        if [ "$CLASS" = "SHARED_LIBRARIES" ]; then
            if [ "$EXTRA" = "both" ]; then
                printf 'LOCAL_SRC_FILES_64 := %s/lib64/%s\n' "$SRC" "$FILE"
                printf 'LOCAL_SRC_FILES_32 := %s/lib/%s\n' "$SRC" "$FILE"
                #if [ "$VENDOR_PKG" = "true" ]; then
                #    echo "LOCAL_MODULE_PATH_64 := \$(TARGET_OUT_VENDOR_SHARED_LIBRARIES)"
                #    echo "LOCAL_MODULE_PATH_32 := \$(2ND_TARGET_OUT_VENDOR_SHARED_LIBRARIES)"
                #else
                #    echo "LOCAL_MODULE_PATH_64 := \$(TARGET_OUT_SHARED_LIBRARIES)"
                #    echo "LOCAL_MODULE_PATH_32 := \$(2ND_TARGET_OUT_SHARED_LIBRARIES)"
                #fi
            elif [ "$EXTRA" = "64" ]; then
                printf 'LOCAL_SRC_FILES := %s/lib64/%s\n' "$SRC" "$FILE"
            else
                printf 'LOCAL_SRC_FILES := %s/lib/%s\n' "$SRC" "$FILE"
            fi
            if [ "$EXTRA" != "none" ]; then
                printf 'LOCAL_MULTILIB := %s\n' "$EXTRA"
            fi
        elif [ "$CLASS" = "APPS" ]; then
            if [ -z "$ARGS" ]; then
                if [ "$EXTRA" = "priv-app" ]; then
                    SRC="$SRC/priv-app"
                else
                    SRC="$SRC/app"
                fi
            fi
            printf 'LOCAL_SRC_FILES := %s/%s\n' "$SRC" "$FILE"
            local CERT=platform
            if [ ! -z "$ARGS" ]; then
                CERT="$ARGS"
            fi
            printf 'LOCAL_CERTIFICATE := %s\n' "$CERT"
        elif [ "$CLASS" = "JAVA_LIBRARIES" ]; then
            printf 'LOCAL_SRC_FILES := %s/framework/%s\n' "$SRC" "$FILE"
        elif [ "$CLASS" = "ETC" ]; then
            printf 'LOCAL_SRC_FILES := %s/etc/%s\n' "$SRC" "$FILE"
        elif [ "$CLASS" = "EXECUTABLES" ]; then
            if [ "$ARGS" = "rootfs" ]; then
                SRC="$SRC/rootfs"
                if [ "$EXTRA" = "sbin" ]; then
                    SRC="$SRC/sbin"
                    printf '%s\n' "LOCAL_MODULE_PATH := \$(TARGET_ROOT_OUT_SBIN)"
                    printf '%s\n' "LOCAL_UNSTRIPPED_PATH := \$(TARGET_ROOT_OUT_SBIN_UNSTRIPPED)"
                fi
            else
                SRC="$SRC/bin"
            fi
            printf 'LOCAL_SRC_FILES := %s/%s\n' "$SRC" "$FILE"
            unset EXTENSION
        else
            printf 'LOCAL_SRC_FILES := %s/%s\n' "$SRC" "$FILE"
        fi
        printf 'LOCAL_MODULE_TAGS := optional\n'
        printf 'LOCAL_MODULE_CLASS := %s\n' "$CLASS"
        if [ "$CLASS" = "APPS" ]; then
            printf 'LOCAL_DEX_PREOPT := false\n'
        fi
        if [ ! -z "$EXTENSION" ]; then
            printf 'LOCAL_MODULE_SUFFIX := .%s\n' "$EXTENSION"
        fi
        if [ "$EXTRA" = "priv-app" ]; then
            printf 'LOCAL_PRIVILEGED_MODULE := true\n'
        fi
        if [ "$VENDOR_PKG" = "true" ]; then
            printf 'LOCAL_PROPRIETARY_MODULE := true\n'
        fi
        printf 'include $(BUILD_PREBUILT)\n\n'
    done
}

#
# write_product_packages:
#
# This function will create BUILD_PREBUILT entries in the
# Android.mk and associated PRODUCT_PACKAGES list in the
# product makefile for all files in the blob list which
# start with a single dash (-) character.
#
function write_product_packages() {
    PACKAGE_LIST=()

    local COUNT=${#PRODUCT_PACKAGES_LIST[@]}

    if [ "$COUNT" = "0" ]; then
        return 0
    fi

    # Figure out what's 32-bit, what's 64-bit, and what's multilib
    # I really should not be doing this in bash due to shitty array passing :(
    local T_LIB32=( $(prefix_match "lib/") )
    local T_LIB64=( $(prefix_match "lib64/") )
    local MULTILIBS=( $(comm -12 <(printf '%s\n' "${T_LIB32[@]}") <(printf '%s\n' "${T_LIB64[@]}")) )
    local LIB32=( $(comm -23 <(printf '%s\n'  "${T_LIB32[@]}") <(printf '%s\n' "${MULTILIBS[@]}")) )
    local LIB64=( $(comm -23 <(printf '%s\n' "${T_LIB64[@]}") <(printf '%s\n' "${MULTILIBS[@]}")) )

    if [ "${#MULTILIBS[@]}" -gt "0" ]; then
        write_packages "SHARED_LIBRARIES" "false" "both" "MULTILIBS" >> "$ANDROIDMK"
    fi
    if [ "${#LIB32[@]}" -gt "0" ]; then
        write_packages "SHARED_LIBRARIES" "false" "32" "LIB32" >> "$ANDROIDMK"
    fi
    if [ "${#LIB64[@]}" -gt "0" ]; then
        write_packages "SHARED_LIBRARIES" "false" "64" "LIB64" >> "$ANDROIDMK"
    fi

    local T_V_LIB32=( $(prefix_match "vendor/lib/") )
    local T_V_LIB64=( $(prefix_match "vendor/lib64/") )
    local V_MULTILIBS=( $(comm -12 <(printf '%s\n' "${T_V_LIB32[@]}") <(printf '%s\n' "${T_V_LIB64[@]}")) )
    local V_LIB32=( $(comm -23 <(printf '%s\n' "${T_V_LIB32[@]}") <(printf '%s\n' "${V_MULTILIBS[@]}")) )
    local V_LIB64=( $(comm -23 <(printf '%s\n' "${T_V_LIB64[@]}") <(printf '%s\n' "${V_MULTILIBS[@]}")) )

    if [ "${#V_MULTILIBS[@]}" -gt "0" ]; then
        write_packages "SHARED_LIBRARIES" "true" "both" "V_MULTILIBS" >> "$ANDROIDMK"
    fi
    if [ "${#V_LIB32[@]}" -gt "0" ]; then
        write_packages "SHARED_LIBRARIES" "true" "32" "V_LIB32" >> "$ANDROIDMK"
    fi
    if [ "${#V_LIB64[@]}" -gt "0" ]; then
        write_packages "SHARED_LIBRARIES" "true" "64" "V_LIB64" >> "$ANDROIDMK"
    fi

    # Apps
    local APPS=( $(prefix_match "app/") )
    if [ "${#APPS[@]}" -gt "0" ]; then
        write_packages "APPS" "false" "" "APPS" >> "$ANDROIDMK"
    fi
    local PRIV_APPS=( $(prefix_match "priv-app/") )
    if [ "${#PRIV_APPS[@]}" -gt "0" ]; then
        write_packages "APPS" "false" "priv-app" "PRIV_APPS" >> "$ANDROIDMK"
    fi
    local V_APPS=( $(prefix_match "vendor/app/") )
    if [ "${#V_APPS[@]}" -gt "0" ]; then
        write_packages "APPS" "true" "" "V_APPS" >> "$ANDROIDMK"
    fi
    local V_PRIV_APPS=( $(prefix_match "vendor/priv-app/") )
    if [ "${#V_PRIV_APPS[@]}" -gt "0" ]; then
        write_packages "APPS" "true" "priv-app" "V_PRIV_APPS" >> "$ANDROIDMK"
    fi

    # Framework
    local FRAMEWORK=( $(prefix_match "framework/") )
    if [ "${#FRAMEWORK[@]}" -gt "0" ]; then
        write_packages "JAVA_LIBRARIES" "false" "" "FRAMEWORK" >> "$ANDROIDMK"
    fi

    # Etc
    local ETC=( $(prefix_match "etc/") )
    if [ "${#ETC[@]}" -gt "0" ]; then
        write_packages "ETC" "false" "" "ETC" >> "$ANDROIDMK"
    fi
    local V_ETC=( $(prefix_match "vendor/etc/") )
    if [ "${#V_ETC[@]}" -gt "0" ]; then
        write_packages "ETC" "false" "" "V_ETC" >> "$ANDROIDMK"
    fi

    # Executables
    local BIN=( $(prefix_match "bin/") )
    if [ "${#BIN[@]}" -gt "0"  ]; then
        write_packages "EXECUTABLES" "false" "" "BIN" >> "$ANDROIDMK"
    fi
    local V_BIN=( $(prefix_match "vendor/bin/") )
    if [ "${#V_BIN[@]}" -gt "0" ]; then
        write_packages "EXECUTABLES" "true" "" "V_BIN" >> "$ANDROIDMK"
    fi
    local SBIN=( $(prefix_match "sbin/") )
    if [ "${#SBIN[@]}" -gt "0" ]; then
        write_packages "EXECUTABLES" "false" "sbin" "SBIN" >> "$ANDROIDMK"
    fi


    # Actually write out the final PRODUCT_PACKAGES list
    local PACKAGE_COUNT=${#PACKAGE_LIST[@]}

    if [ "$PACKAGE_COUNT" -eq "0" ]; then
        return 0
    fi

    printf '\n%s\n' "PRODUCT_PACKAGES += \\" >> "$PRODUCTMK"
    for (( i=1; i<PACKAGE_COUNT+1; i++ )); do
        local LINEEND=" \\"
        if [ "$i" -eq "$PACKAGE_COUNT" ]; then
            LINEEND=""
        fi
        printf '    %s%s\n' "${PACKAGE_LIST[$i-1]}" "$LINEEND" >> "$PRODUCTMK"
    done
}

#
# write_header:
#
# $1: file which will be written to
#
# writes out the copyright header with the current year.
# note that this is not an append operation, and should
# be executed first!
#
function write_header() {
    YEAR=$(date +"%Y")

    [ "$COMMON" -eq 1 ] && local DEVICE="$DEVICE_COMMON"

    cat << EOF > $1
# Copyright (C) $YEAR The CyanogenMod Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This file is generated by device/$VENDOR/$DEVICE/setup-makefiles.sh

EOF
}

#
# write_headers:
#
# $1: devices falling under common to be added to guard - optional
# $2: custom guard - optional
#
# Calls write_header for each of the makefiles and creates
# the initial path declaration and device guard for the
# Android.mk
#
function write_headers() {
    write_header "$ANDROIDMK"

    GUARD="$2"
    if [ -z "$GUARD" ]; then
        GUARD="TARGET_DEVICE"
    fi

    cat << EOF >> "$ANDROIDMK"
LOCAL_PATH := \$(call my-dir)

EOF
    if [ "$COMMON" -ne 1 ]; then
        cat << EOF >> "$ANDROIDMK"
ifeq (\$($GUARD),$DEVICE)

EOF
    else
        if [ -z "$1" ]; then
            echo "Argument with devices to be added to guard must be set!"
            exit 1
        fi
        cat << EOF >> "$ANDROIDMK"
ifneq (\$(filter $1,\$($GUARD)),)

EOF
    fi

    write_header "$BOARDMK"
    write_header "$PRODUCTMK"
}

#
# write_footers:
#
# Closes the inital guard and any other finalization tasks. Must
# be called as the final step.
#
function write_footers() {
    cat << EOF >> "$ANDROIDMK"
endif
EOF
}

# Return success if adb is up and not in recovery
function _adb_connected {
    {
        if [[ "$(adb get-state)" == device ]]
        then
            return 0
        fi
    } 2>/dev/null

    return 1
};

#
# parse_file_list:
#
# $1: input file
#
# Sets PRODUCT_PACKAGES and PRODUCT_COPY_FILES while parsing the input file
#
function parse_file_list() {
    if [ -z "$1" ]; then
        echo "An input file is expected!"
        exit 1
    elif [ ! -f "$1" ]; then
        echo "Input file "$1" does not exist!"
        exit 1
    fi

    PRODUCT_PACKAGES_LIST=()
    PRODUCT_PACKAGES_HASHES=()
    PRODUCT_COPY_FILES_LIST=()
    PRODUCT_COPY_FILES_HASHES=()

    while read -r line; do
        if [ -z "$line" ]; then continue; fi

        # If the line has a pipe delimiter, a sha1 hash should follow.
        # This indicates the file should be pinned and not overwritten
        # when extracting files.
        local SPLIT=(${line//\|/ })
        local COUNT=${#SPLIT[@]}
        local SPEC=${SPLIT[0]}
        local HASH="x"
        if [ "$COUNT" -gt "1" ]; then
            HASH=${SPLIT[1]}
        fi

        # if line starts with a dash, it needs to be packaged
        if [[ "$SPEC" =~ ^- ]]; then
            PRODUCT_PACKAGES_LIST+=("${SPEC#-}")
            PRODUCT_PACKAGES_HASHES+=("$HASH")
        else
            PRODUCT_COPY_FILES_LIST+=("$SPEC")
            PRODUCT_COPY_FILES_HASHES+=("$HASH")
        fi

    done < <(egrep -v '(^#|^[[:space:]]*$)' "$1" | sort | uniq)
}

#
# write_makefiles:
#
# $1: file containing the list of items to extract
#
# Calls write_product_copy_files and write_product_packages on
# the given file and appends to the Android.mk as well as
# the product makefile.
#
function write_makefiles() {
    parse_file_list "$1"
    write_product_copy_files
    write_product_packages
}

#
# append_firmware_calls_to_makefiles:
#
# Appends to Android.mk the calls to all images present in radio folder
# (filesmap file used by releasetools to map firmware images should be kept in the device tree)
#
function append_firmware_calls_to_makefiles() {
    cat << EOF >> "$ANDROIDMK"
ifeq (\$(LOCAL_PATH)/radio, \$(wildcard \$(LOCAL_PATH)/radio))

RADIO_FILES := \$(wildcard \$(LOCAL_PATH)/radio/*)
\$(foreach f, \$(notdir \$(RADIO_FILES)), \\
    \$(call add-radio-file,radio/\$(f)))
\$(call add-radio-file,../../../device/$VENDOR/$DEVICE/radio/filesmap)

endif

EOF
}

#
# get_file:
#
# $1: input file
# $2: target file/folder
# $3: source of the file (can be "adb" or a local folder)
#
# Silently extracts the input file to defined target
# Returns success if file can be pulled from the device or found locally
#
function get_file() {
    local SRC="$3"

    if [ "$SRC" = "adb" ]; then
        # try to pull
        adb pull "$1" "$2" >/dev/null 2>&1 && return 0

        return 1
    else
        # try to copy
        cp -r "$SRC/$1" "$2" 2>/dev/null && return 0

        return 1
    fi
};

#
# oat2dex:
#
# $1: extracted apk|jar (to check if deodex is required)
# $2: odexed apk|jar to deodex
# $3: source of the odexed apk|jar
#
# Convert apk|jar .odex in the corresposing classes.dex
#
function oat2dex() {
    local CM_TARGET="$1"
    local OEM_TARGET="$2"
    local SRC="$3"
    local TARGET=
    local OAT=

    if [ -z "$BAKSMALIJAR" ] || [ -z "$SMALIJAR" ]; then
        export BAKSMALIJAR="$CM_ROOT"/vendor/cm/build/tools/smali/baksmali.jar
        export SMALIJAR="$CM_ROOT"/vendor/cm/build/tools/smali/smali.jar
    fi

    # Extract existing boot.oats to the temp folder
    if [ -z "$ARCHES" ]; then
        echo "Checking if system is odexed and locating boot.oats..."
        for ARCH in "arm64" "arm" "x86_64" "x86"; do
            mkdir -p "$TMPDIR/system/framework/$ARCH"
            if get_file "system/framework/$ARCH/" "$TMPDIR/system/framework/" "$SRC"; then
                ARCHES+="$ARCH "
            else
                rmdir "$TMPDIR/system/framework/$ARCH"
            fi
        done
    fi

    if [ -z "$ARCHES" ]; then
        FULLY_DEODEXED=1 && return 0 # system is fully deodexed, return
    fi

    if [ ! -f "$CM_TARGET" ]; then
        return;
    fi

    if grep "classes.dex" "$CM_TARGET" >/dev/null; then
        return 0 # target apk|jar is already odexed, return
    fi

    for ARCH in $ARCHES; do
        BOOTOAT="$TMPDIR/system/framework/$ARCH/boot.oat"

        local OAT="$(dirname "$OEM_TARGET")/oat/$ARCH/$(basename "$OEM_TARGET" ."${OEM_TARGET##*.}").odex"

        if get_file "$OAT" "$TMPDIR" "$SRC"; then
            java -jar "$BAKSMALIJAR" deodex -o "$TMPDIR/dexout" -b "$BOOTOAT" -d "$TMPDIR" "$TMPDIR/$(basename "$OAT")"
        elif [[ "$CM_TARGET" =~ .jar$ ]]; then
            # try to extract classes.dex from boot.oat for framework jars
            java -jar "$BAKSMALIJAR" deodex -o "$TMPDIR/dexout" -b "$BOOTOAT" -d "$TMPDIR" -e "/$OEM_TARGET" "$BOOTOAT"
        else
            continue
        fi

        java -jar "$SMALIJAR" assemble "$TMPDIR/dexout" -o "$TMPDIR/classes.dex" && break
    done

    rm -rf "$TMPDIR/dexout"
}

#
# init_adb_connection:
#
# Starts adb server and waits for the device
#
function init_adb_connection() {
    adb start-server # Prevent unexpected starting server message from adb get-state in the next line
    if ! _adb_connected; then
        echo "No device is online. Waiting for one..."
        echo "Please connect USB and/or enable USB debugging"
        until _adb_connected; do
            sleep 1
        done
        echo "Device Found."
    fi

    # Retrieve IP and PORT info if we're using a TCP connection
    TCPIPPORT=$(adb devices | egrep '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+[^0-9]+' \
        | head -1 | awk '{print $1}')
    adb root &> /dev/null
    sleep 0.3
    if [ -n "$TCPIPPORT" ]; then
        # adb root just killed our connection
        # so reconnect...
        adb connect "$TCPIPPORT"
    fi
    adb wait-for-device &> /dev/null
    sleep 0.3
}

#
# fix_xml:
#
# $1: xml file to fix
#
function fix_xml() {
    local XML="$1"
    local TEMP_XML="$TMPDIR/`basename "$XML"`.temp"

    grep '^<?xml version' "$XML" > "$TEMP_XML"
    grep -v '^<?xml version' "$XML" >> "$TEMP_XML"

    mv "$TEMP_XML" "$XML"
}

#
# extract:
#
# $1: file containing the list of items to extract
# $2: path to extracted system folder, or "adb" to extract from device
#
function extract() {
    if [ -z "$OUTDIR" ]; then
        echo "Output dir not set!"
        exit 1
    fi

    parse_file_list "$1"

    # Allow failing, so we can try $DEST and/or $FILE
    set +e

    local FILELIST=( ${PRODUCT_COPY_FILES_LIST[@]} ${PRODUCT_PACKAGES_LIST[@]} )
    local HASHLIST=( ${PRODUCT_COPY_FILES_HASHES[@]} ${PRODUCT_PACKAGES_HASHES[@]} )
    local COUNT=${#FILELIST[@]}
    local SRC="$2"
    local OUTPUT_ROOT="$CM_ROOT"/"$OUTDIR"/proprietary
    local OUTPUT_TMP="$TMPDIR"/"$OUTDIR"/proprietary

    if [ "$SRC" = "adb" ]; then
        init_adb_connection
    fi

    if [ "$VENDOR_STATE" -eq "0" ]; then
        echo "Cleaning output directory ($OUTPUT_ROOT).."
        rm -rf "${OUTPUT_TMP:?}"
        mkdir -p "${OUTPUT_TMP:?}"
        mv "${OUTPUT_ROOT:?}/"* "${OUTPUT_TMP:?}/"
        VENDOR_STATE=1
    fi

    echo "Extracting $COUNT files in $1 from $SRC:"

    for (( i=1; i<COUNT+1; i++ )); do

        local FROM=$(target_file "${FILELIST[$i-1]}")
        local ARGS=$(target_args "${FILELIST[$i-1]}")
        local SPLIT=(${FILELIST[$i-1]//:/ })
        local FILE="${SPLIT[0]#-}"
        local OUTPUT_DIR="$OUTPUT_ROOT"
        local TMP_DIR="$OUTPUT_TMP"
        local TARGET=

        if [ "$ARGS" = "rootfs" ]; then
            TARGET="$FROM"
            OUTPUT_DIR="$OUTPUT_DIR/rootfs"
            TMP_DIR="$TMP_DIR/rootfs"
        else
            TARGET="system/$FROM"
            FILE="system/$FILE"
        fi

        if [ "$SRC" = "adb" ]; then
            printf '  - %s .. ' "/$TARGET"
        else
            printf '  - %s \n' "/$TARGET"
        fi

        local DIR=$(dirname "$FROM")
        if [ ! -d "$OUTPUT_DIR/$DIR" ]; then
            mkdir -p "$OUTPUT_DIR/$DIR"
        fi
        local DEST="$OUTPUT_DIR/$FROM"

        if [ "$SRC" = "adb" ]; then
            # Try CM target first
            adb pull "/$TARGET" "$DEST"
            # if file does not exist try OEM target
            if [ "$?" != "0" ]; then
                adb pull "/$FILE" "$DEST"
            fi
        else
            # Try OEM target first
            if [ -f "$SRC/$FILE" ]; then
                cp "$SRC/$FILE" "$DEST"
            # if file does not exist try CM target
            elif [ -f "$SRC/$TARGET" ]; then
                cp "$SRC/$TARGET" "$DEST"
            else
                printf '    !! file not found in source\n'
            fi
        fi

        if [ "$?" == "0" ]; then
            # Deodex apk|jar if that's the case
            if [[ "$FULLY_DEODEXED" -ne "1" && "$DEST" =~ .(apk|jar)$ ]]; then
                oat2dex "$DEST" "$FILE" "$SRC"
                if [ -f "$TMPDIR/classes.dex" ]; then
                    zip -gjq "$DEST" "$TMPDIR/classes.dex"
                    rm "$TMPDIR/classes.dex"
                    printf '    (updated %s from odex files)\n' "/$FILE"
                fi
            elif [[ "$DEST" =~ .xml$ ]]; then
                fix_xml "$DEST"
            fi
        fi

        # Check pinned files
        local HASH="${HASHLIST[$i-1]}"
        if [ "$DISABLE_PINNING" != "1" ] && [ ! -z "$HASH" ] && [ "$HASH" != "x" ]; then
            local KEEP=""
            local TMP="$TMP_DIR/$FROM"
            if [ -f "$TMP" ]; then
                if [ ! -f "$DEST" ]; then
                    KEEP="1"
                else
                    local DEST_HASH=$(sha1sum "$DEST" | awk '{print $1}' )
                    if [ "$DEST_HASH" != "$HASH" ]; then
                        KEEP="1"
                    fi
                fi
                if [ "$KEEP" = "1" ]; then
                    local TMP_HASH=$(sha1sum "$TMP" | awk '{print $1}' )
                    if [ "$TMP_HASH" = "$HASH" ]; then
                        printf '    + (keeping pinned file with hash %s)\n' "$HASH"
                        cp -p "$TMP" "$DEST"
                    fi
                fi
            fi
        fi

        if [ -f "$DEST" ]; then
            local TYPE="${DIR##*/}"
            if [ "$TYPE" = "bin" -o "$TYPE" = "sbin" ]; then
                chmod 755 "$DEST"
            else
                chmod 644 "$DEST"
            fi
        fi

    done

    # Don't allow failing
    set -e
}

#
# extract_firmware:
#
# $1: file containing the list of items to extract
# $2: path to extracted radio folder
#
function extract_firmware() {
    if [ -z "$OUTDIR" ]; then
        echo "Output dir not set!"
        exit 1
    fi

    parse_file_list "$1"

    # Don't allow failing
    set -e

    local FILELIST=( ${PRODUCT_COPY_FILES_LIST[@]} )
    local COUNT=${#FILELIST[@]}
    local SRC="$2"
    local OUTPUT_DIR="$CM_ROOT"/"$OUTDIR"/radio

    if [ "$VENDOR_RADIO_STATE" -eq "0" ]; then
        echo "Cleaning firmware output directory ($OUTPUT_DIR).."
        rm -rf "${OUTPUT_DIR:?}/"*
        VENDOR_RADIO_STATE=1
    fi

    echo "Extracting $COUNT files in $1 from $SRC:"

    for (( i=1; i<COUNT+1; i++ )); do
        local FILE="${FILELIST[$i-1]}"
        printf '  - %s \n' "/radio/$FILE"

        if [ ! -d "$OUTPUT_DIR" ]; then
            mkdir -p "$OUTPUT_DIR"
        fi
        cp "$SRC/$FILE" "$OUTPUT_DIR/$FILE"
        chmod 644 "$OUTPUT_DIR/$FILE"
    done
}

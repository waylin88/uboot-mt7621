#!/bin/bash

# toolchain path
Toolchain=$(cd ../openwrt*/toolchain-mipsel*/bin; pwd)'/mipsel-openwrt-linux-'
Staging=${Toolchain%/toolchain-*}

echo "CROSS_COMPILE=${Toolchain}"
echo "STAGING_DIR=${Toolchain%/toolchain-*}"
cd $(dirname "$0")

# arguments:
# $1	string: flash type
# $2	string: partition table
# $3	string: kernel offset
# $4	number: reset pin
# $5	number: sysled gpio
# $6	number: cpu frequency
# $7	number: ram frequency
# $8	string: ddr param
# $9	string: baud rate

echo "Parse flash type: $1"
# simple check if partition table is valid
if [ -z $( echo -n "$2" | grep '),-(firmware)') ]; then
	echo "Invalid mtd partition table!"
	exit 1
fi
DEFCONFIG="configs/mt7621_build_defconfig"
if [ "$1" = 'NOR' ]; then
	cp configs/mt7621_nor_template_defconfig ${DEFCONFIG}
	echo -e "CONFIG_MTDPARTS_DEFAULT=\"mtdparts=raspi:$2\"" >> ${DEFCONFIG}
elif [ "$1" = 'NAND' ]; then
	cp configs/mt7621_nand_template_defconfig ${DEFCONFIG}
	echo -e "CONFIG_MTDPARTS_DEFAULT=\"mtdparts=nand0:$2\"" >> ${DEFCONFIG}
else
	cp configs/mt7621_nmbm_template_defconfig ${DEFCONFIG}
	echo -e "CONFIG_MTDPARTS_DEFAULT=\"mtdparts=nmbm0:$2\"" >> ${DEFCONFIG}
fi
echo "set partition table: $2"

echo "set kernel offset: $3"
if [ "$1" = 'NOR' ]; then
	echo "CONFIG_DEFAULT_NOR_KERNEL_OFFSET=$3" >> ${DEFCONFIG}
else
	echo "CONFIG_DEFAULT_NAND_KERNEL_OFFSET=$3" >> ${DEFCONFIG}
fi

echo -e "#ifndef __CONFIG_MT7621_RESET_LED\n#define __CONFIG_MT7621_RESET_LED" \
	>> ./include/configs/mt7621-common.h
if [ "$4" -ge 0 -a "$4" -le 48 ]; then
	echo "set reset button pin: $4"
	echo "CONFIG_FAILSAFE_ON_BUTTON=y" >> ${DEFCONFIG}
	echo "#define MT7621_BUTTON_RESET $4" >> ./include/configs/mt7621-common.h
else
	echo "Reset button is disabled!"
fi

if [ "$5" -ge 0 -a "$5" -le 48 ]; then
	echo "set system led pin: $5"
	echo "#define MT7621_LED_STATUS1 $5" >> ./include/configs/mt7621-common.h
else
	echo "System LED is disabled!"
fi
echo "#endif" >> ./include/configs/mt7621-common.h

if [ "$6" -ge 400 -a "$6" -le 1200 ]; then
	echo "set CPU frequency: $6 MHz"
	echo "CONFIG_MT7621_CPU_FREQ_LEGACY=$6" >> ${DEFCONFIG}
else
	echo "Invalid CPU Frequency!"
	exit 1
fi

echo "set DRAM frequency: $7 MT/s"
echo "CONFIG_MT7621_DRAM_FREQ_$7_LEGACY=y" >> ${DEFCONFIG}

echo "Parse DDR init parameters: $8"
case "$8" in
DDR2-64MiB)
	echo "CONFIG_MT7621_DRAM_DDR2_512M_LEGACY=y" >> ${DEFCONFIG}
	;;
DDR2-128MiB)
	echo "CONFIG_MT7621_DRAM_DDR2_1024M_LEGACY=y" >> ${DEFCONFIG}
	;;
DDR2-W9751G6KB-64MiB-1066MHz)
	echo "CONFIG_MT7621_DRAM_DDR2_512M_W9751G6KB_A02_1066MHZ_LEGACY=y" >> ${DEFCONFIG}
	;;
DDR2-W971GG6KB25-128MiB-800MHz)
	echo "CONFIG_MT7621_DRAM_DDR2_1024M_W971GG6KB25_800MHZ_LEGACY=y" >> ${DEFCONFIG}
	;;
DDR2-W971GG6KB18-128MiB-1066MHz)
	echo "CONFIG_MT7621_DRAM_DDR2_1024M_W971GG6KB18_1066MHZ_LEGACY=y" >> ${DEFCONFIG}
	;;
DDR3-128MiB)
	echo "CONFIG_MT7621_DRAM_DDR3_1024M_LEGACY=y" >> ${DEFCONFIG}
	;;
DDR3-256MiB)
	echo "CONFIG_MT7621_DRAM_DDR3_2048M_LEGACY=y" >> ${DEFCONFIG}
	;;
DDR3-512MiB)
	echo "CONFIG_MT7621_DRAM_DDR3_4096M_LEGACY=y" >> ${DEFCONFIG}
	if [ -n $(cat ${DEFCONFIG} | grep MT7621_DRAM_FREQ_1200_LEGACY) ]; then
		echo "The max DRAM speed for 512 MiB RAM is 1066 MT/s"
		sed -i 's/MT7621_DRAM_FREQ_1200_LEGACY/MT7621_DRAM_FREQ_1066_LEGACY/' ${DEFCONFIG}
	fi
	;;
DDR3-128MiB-KGD)
	echo "CONFIG_MT7621_DRAM_DDR3_1024M_KGD_LEGACY=y" >> ${DEFCONFIG}
	;;
esac

echo "Set baud rate: $9"
if [ "$9" = '57600' ]; then
	echo "CONFIG_BAUDRATE=57600" >> ${DEFCONFIG}
else
	echo "CONFIG_BAUDRATE=115200" >> ${DEFCONFIG}
fi
# ================= 自定义 MAC 修改命令注入开始 =================
echo "Injecting setmacrom command..."

cat << 'EOF' > ./common/cmd_setmac.c
#include <common.h>
#include <command.h>
#include <u-boot/md5.h>
#include <linux/mtd/mtd.h>

static unsigned char char_to_hex(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return 0;
}

static int do_setmacrom(cmd_tbl_t *cmdtp, int flag, int argc, char * const argv[]) {
    if (argc != 2 || strlen(argv[1]) != 12) {
        printf("Usage: setmacrom <12-char-mac>\nExample: setmacrom b880352502a0\n");
        return CMD_RET_USAGE;
    }

    char *mac_str = argv[1];
    unsigned char data[10];
    unsigned char hash[16];
    char md5_str1[33];
    char md5_str2[33];
    char input_buffer[14]; // 12字节MAC + 1字节换行符 + \0
    int i;

    // 1. 解析原始 MAC 字节 (写入 Flash 用)
    for (i = 0; i < 6; i++) {
        data[i] = (char_to_hex(mac_str[i * 2]) << 4) | char_to_hex(mac_str[i * 2 + 1]);
    }

    // 2. 模拟 Shell 的 echo "mac" | md5sum
    // 注意：echo 默认带换行符 \n (0x0A)
    snprintf(input_buffer, sizeof(input_buffer), "%s\n", mac_str);
    
    // 第一次 MD5: md5(mac + \n)
    md5((unsigned char *)input_buffer, 13, hash);
    for (i = 0; i < 16; i++) sprintf(md5_str1 + (i * 2), "%02x", hash[i]);
    
    // 第二次 MD5: 模拟 cut -c 1-9 (取前9位) | md5sum
    // 注意：前9位后面也要补一个换行符 \n 才能匹配 Shell 的 echo
    char input_buffer2[11];
    strncpy(input_buffer2, md5_str1, 9);
    input_buffer2[9] = '\n'; 
    
    md5((unsigned char *)input_buffer2, 10, hash);
    for (i = 0; i < 16; i++) sprintf(md5_str2 + (i * 2), "%02x", hash[i]);

    // 3. 提取校验码 (Shell cut -c 20-27 对应索引 19-26)
    // 预期结果对于 a0 应该是 4f5d3959
    for (i = 0; i < 4; i++) {
        char tmp[3] = { md5_str2[19 + i*2], md5_str2[20 + i*2], 0 };
        data[6 + i] = (unsigned char)simple_strtoul(tmp, NULL, 16);
    }

    // 4. MTD 写入逻辑
    struct mtd_info *mtd = get_mtd_device_nm("nand0");
    if (IS_ERR_OR_NULL(mtd)) mtd = get_mtd_device_nm("nmbm0");

    if (IS_ERR_OR_NULL(mtd)) {
        printf("MTD device not found!\n");
        return CMD_RET_FAILURE;
    }

    uint32_t off = 0xE0000; 
    struct erase_info ei;
    size_t write_len;

    printf("Updating MTD3: MAC=%02x%02x%02x%02x%02x%02x, Checksum=%02x%02x%02x%02x\n", 
            data[0], data[1], data[2], data[3], data[4], data[5],
            data[6], data[7], data[8], data[9]);

    memset(&ei, 0, sizeof(ei));
    ei.mtd = mtd; ei.addr = off; ei.len = 0x20000;
    
    if (mtd->_erase(mtd, &ei)) return CMD_RET_FAILURE;
    if (mtd->_write(mtd, off, 10, &write_len, data)) return CMD_RET_FAILURE;

    printf("Success!\n");
    return CMD_RET_SUCCESS;
}

U_BOOT_CMD(
    setmacrom, 2, 0, do_setmacrom,
    "Update MAC with Shell-compatible MD5 checksum",
    "<mac>"
);
EOF

# 修改 Makefile 和配置文件的逻辑保持不变
if [ -f "./common/Makefile" ]; then
    grep -q "cmd_setmac.o" ./common/Makefile || echo "obj-y += cmd_setmac.o" >> ./common/Makefile
fi
echo "CONFIG_CMD_NAND=y" >> ${DEFCONFIG}
# ================= 自定义 MAC 修改命令注入结束 =================


make mt7621_build_defconfig
make CROSS_COMPILE=${Toolchain} STAGING_DIR=${Staging}
make savedefconfig
mkdir archive
cat defconfig > archive/mt7621_defconfig
mv u-boot-mt7621.bin archive/
mv u-boot.img archive/

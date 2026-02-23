#include <common.h>
#include <command.h>
#include <nand.h>
#include <u-boot/md5.h> // 使用 U-Boot 自带的 MD5 库

// 将 2 位字符转为 1 字节十六进制
static unsigned char char_to_hex(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return 0;
}

static int do_setmacrom(struct cmd_tbl *cmdtp, int flag, int argc, char *const argv[]) {
    if (argc != 2 || strlen(argv[1]) != 12) {
        printf("Usage: setmacrom <12-char-mac>\nExample: setmacrom b880352502ac\n");
        return CMD_RET_USAGE;
    }

    char *mac_str = argv[1];
    unsigned char data[10];
    unsigned char hash1[16];
    unsigned char hash2[16];
    char hex_out[33];
    int i;

    // 1. 解析 MAC 前 6 字节
    for (i = 0; i < 6; i++) {
        data[i] = (char_to_hex(mac_str[i * 2]) << 4) | char_to_hex(mac_str[i * 2 + 1]);
    }

    // 2. 计算校验码 (你的算法: MAC -> MD5 -> cut 1-9 -> MD5 -> cut 20-27)
    // 第一次 MD5
    md5((unsigned char *)mac_str, 12, hash1);
    for (i = 0; i < 16; i++) sprintf(hex_out + (i * 2), "%02x", hash1[i]);
    
    // 取前 9 位进行第二次 MD5
    md5((unsigned char *)hex_out, 9, hash2);
    for (i = 0; i < 16; i++) sprintf(hex_out + (i * 2), "%02x", hash2[i]);

    // 取第二次 MD5 的第 20 到 27 位 (对应 C 索引 19-26)
    // 赋值给 data 的最后 4 字节
    for (i = 0; i < 4; i++) {
        char tmp[3] = { hex_out[19 + i*2], hex_out[20 + i*2], 0 };
        data[6 + i] = (unsigned char)simple_strtoul(tmp, NULL, 16);
    }

    // 3. 准备写入 Flash (mtd3 物理地址 0xE0000)
    nand_info_t *nand = &nand_info[0];
    uint32_t off = 0xE0000;
    size_t len = 0x20000; // 128KB 分区
    size_t write_len = 10;

    printf("Updating MACROM to %s with checksum...\n", mac_str);

    if (nand_erase(nand, off, len)) {
        printf("Error: NAND erase failed!\n");
        return CMD_RET_FAILURE;
    }

    if (nand_write(nand, off, &write_len, data)) {
        printf("Error: NAND write failed!\n");
        return CMD_RET_FAILURE;
    }

    printf("Success! MAC and Checksum updated permanently.\n");
    return CMD_RET_SUCCESS;
}

U_BOOT_CMD(
    setmacrom, 2, 0, do_setmacrom,
    "Update MAC and auto-calculate checksum to MTD3",
    "<mac> - 12 characters hex string"
);

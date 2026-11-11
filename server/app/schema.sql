-- ============================================================================
--  兜鱼复刻版 · 授权服务数据库（MySQL 5.7+ / MariaDB 10.3+）
--  字符集 utf8mb4；所有金额 DECIMAL(10,2)；所有时间 *要么* 是毫秒 BIGINT，
--  *要么* 是 DATETIME（命名后缀区分：*_ms 是毫秒时间戳）。
--
--  初始化：
--    mysql -uroot -p < server/app/schema.sql
--  或在 phpstudy / 宝塔 里新建库 douy_license（utf8mb4_general_ci）后导入本文件。
-- ============================================================================

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

-- ---------------------------------------------------------------- 账号
CREATE TABLE IF NOT EXISTS `douy_accounts` (
  `id`             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `username`       VARCHAR(32)  NOT NULL COMMENT '3-20 位字母数字下划线',
  `password_hash`  VARCHAR(255) NOT NULL COMMENT 'password_hash(PASSWORD_DEFAULT)',
  `email`          VARCHAR(190) NOT NULL,
  `referral_code`  VARCHAR(32)      NULL COMMENT '本账号的推荐码',
  `referred_by`    BIGINT UNSIGNED  NULL COMMENT '推荐人账号 id',
  `status`         ENUM('active','disabled') NOT NULL DEFAULT 'active',
  `created_at`     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `last_login_at`  DATETIME NULL,
  `last_login_ip`  VARCHAR(45) NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_username` (`username`),
  UNIQUE KEY `uk_email` (`email`),
  KEY `idx_referral` (`referral_code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='账号（原版：register/login）';

-- ---------------------------------------------------------------- 设备
CREATE TABLE IF NOT EXISTS `douy_devices` (
  `id`             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `device_id`      CHAR(40)     NOT NULL COMMENT 'SHA256(公钥DER) 前 40 hex',
  `account_id`     BIGINT UNSIGNED NULL COMMENT '首次绑定时回填',
  `platform`       VARCHAR(16)  NOT NULL DEFAULT 'ios',
  `key_id`         VARCHAR(32)  NOT NULL DEFAULT 'ec-p256-1' COMMENT 'ec-p256-1 / ed25519-1',
  `public_key`     TEXT         NOT NULL COMMENT 'base64：ECDSA 为 X.509 DER，Ed25519 为 32B 裸钥',
  `ios_version`    VARCHAR(32)  NULL,
  `bundle_id`      VARCHAR(128) NULL,
  `model`          VARCHAR(64)  NULL,
  `module_hash`    CHAR(64)     NULL COMMENT '插件 __text 的 SHA256（防篡改）',
  `blocked`        TINYINT(1)   NOT NULL DEFAULT 0,
  `first_seen_ms`  BIGINT       NOT NULL,
  `last_seen_ms`   BIGINT       NOT NULL,
  `note`           VARCHAR(255) NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_device` (`device_id`),
  KEY `idx_account` (`account_id`),
  KEY `idx_blocked` (`blocked`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='设备身份（原版：device_id / 本机签名）';

-- ---------------------------------------------------------------- 商品/套餐
CREATE TABLE IF NOT EXISTS `douy_products` (
  `id`          INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `software_id` VARCHAR(64)  NOT NULL COMMENT '如 douy_ios_injection',
  `name`        VARCHAR(64)  NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_software` (`software_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `douy_plans` (
  `id`          INT UNSIGNED NOT NULL AUTO_INCREMENT,
  `software_id` VARCHAR(64)  NOT NULL,
  `title`       VARCHAR(64)  NOT NULL,
  `days_valid`  INT UNSIGNED NOT NULL,
  `price`       DECIMAL(10,2) NOT NULL,
  `qr_code_url` VARCHAR(500) NOT NULL COMMENT '必须 https://',
  `recommend`   TINYINT(1)   NOT NULL DEFAULT 0,
  `sort_order`  INT          NOT NULL DEFAULT 0,
  `active`      TINYINT(1)   NOT NULL DEFAULT 1,
  PRIMARY KEY (`id`),
  KEY `idx_software_active` (`software_id`,`active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='原版：/api/payment_plans';

-- ---------------------------------------------------------------- 卡密批次与卡密
CREATE TABLE IF NOT EXISTS `douy_card_batches` (
  `id`         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `name`       VARCHAR(64)  NOT NULL,
  `plan_id`    INT UNSIGNED NULL,
  `days`       INT UNSIGNED NOT NULL,
  `quantity`   INT UNSIGNED NOT NULL DEFAULT 0,
  `created_by` VARCHAR(64)  NOT NULL DEFAULT 'cli',
  `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `note`       VARCHAR(255) NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `douy_cards` (
  `id`             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `key_code`       VARCHAR(64)  NOT NULL COMMENT 'DOUY-XXXX-XXXX-XXXX',
  `masked`         VARCHAR(64)  NOT NULL COMMENT 'DOUY-****-9F2A',
  `batch_id`       BIGINT UNSIGNED NULL,
  `plan_id`        INT UNSIGNED NULL,
  `days`           INT UNSIGNED NOT NULL,
  `account_id`     BIGINT UNSIGNED NULL,
  `device_id`      CHAR(40)     NULL,
  `status`         ENUM('unused','standby','bound','expired','revoked') NOT NULL DEFAULT 'unused'
                   COMMENT 'unused=未售/未绑  standby=已在卡包未计时  bound=计时中  expired  revoked',
  `duration_ms`    BIGINT NOT NULL DEFAULT 0 COMMENT '购买时长（毫秒）',
  `activated_at_ms` BIGINT NULL COMMENT '首次绑定时间（开始计时）',
  `expires_ms`     BIGINT NULL COMMENT '到期时间',
  `order_id`       BIGINT UNSIGNED NULL,
  `note`           VARCHAR(255) NULL,
  `created_at`     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at`     DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_key` (`key_code`),
  KEY `idx_account_status` (`account_id`,`status`),
  KEY `idx_device` (`device_id`),
  KEY `idx_expires` (`expires_ms`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='卡密（原版：key_code / masked / expires_ms / days）';

-- ---------------------------------------------------------------- 绑定历史
CREATE TABLE IF NOT EXISTS `douy_bindings` (
  `id`         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `card_id`    BIGINT UNSIGNED NOT NULL,
  `device_id`  CHAR(40)     NOT NULL,
  `account_id` BIGINT UNSIGNED NULL,
  `action`     ENUM('bind','unbind','move','auto_switch','revoke') NOT NULL,
  `reason`     VARCHAR(255) NULL,
  `ip`         VARCHAR(45)  NULL,
  `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `idx_card` (`card_id`),
  KEY `idx_device` (`device_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------- 短期租约
CREATE TABLE IF NOT EXISTS `douy_leases` (
  `id`            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `token`         CHAR(64)     NOT NULL COMMENT '租约令牌（客户端持有）',
  `card_id`       BIGINT UNSIGNED NOT NULL,
  `device_id`     CHAR(40)     NOT NULL,
  `account_id`    BIGINT UNSIGNED NULL,
  `generation`    INT UNSIGNED NOT NULL DEFAULT 1,
  `issued_at_ms`  BIGINT NOT NULL,
  `expires_ms`    BIGINT NOT NULL,
  `revoked`       TINYINT(1) NOT NULL DEFAULT 0,
  `last_seen_ms`  BIGINT NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_token` (`token`),
  KEY `idx_device_card` (`device_id`,`card_id`),
  KEY `idx_expires` (`expires_ms`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='90 秒短期租约（原版：lease / IOS_LEASE_REJECTED）';

-- ---------------------------------------------------------------- 会话
CREATE TABLE IF NOT EXISTS `douy_sessions` (
  `id`           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `token`        CHAR(64)     NOT NULL,
  `account_id`   BIGINT UNSIGNED NOT NULL,
  `device_id`    CHAR(40)     NULL,
  `created_at_ms` BIGINT NOT NULL,
  `expires_at_ms` BIGINT NOT NULL,
  `revoked`      TINYINT(1) NOT NULL DEFAULT 0,
  `ip`           VARCHAR(45) NULL,
  `ua`           VARCHAR(255) NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_token` (`token`),
  KEY `idx_account` (`account_id`,`revoked`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------- 登录挑战
CREATE TABLE IF NOT EXISTS `douy_challenges` (
  `id`         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `challenge`  CHAR(64)     NOT NULL,
  `username`   VARCHAR(32)  NOT NULL,
  `device_id`  CHAR(40)     NULL,
  `created_at_ms` BIGINT NOT NULL,
  `expires_at_ms` BIGINT NOT NULL,
  `used`       TINYINT(1) NOT NULL DEFAULT 0,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_challenge` (`challenge`),
  KEY `idx_username` (`username`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='原版：challenge / login_session_protocol';

-- ---------------------------------------------------------------- 防重放 nonce
CREATE TABLE IF NOT EXISTS `douy_nonces` (
  `nonce`      CHAR(32) NOT NULL,
  `device_id`  CHAR(40) NULL,
  `created_at_ms` BIGINT NOT NULL,
  PRIMARY KEY (`nonce`),
  KEY `idx_created` (`created_at_ms`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------- 订单
CREATE TABLE IF NOT EXISTS `douy_orders` (
  `id`           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `account_id`   BIGINT UNSIGNED NOT NULL,
  `plan_id`      INT UNSIGNED NOT NULL,
  `days`         INT UNSIGNED NOT NULL,
  `price`        DECIMAL(10,2) NOT NULL,
  `status`       ENUM('pending','paid','cancelled','refunded') NOT NULL DEFAULT 'pending',
  `remark_code`  VARCHAR(32)  NOT NULL COMMENT '付款备注码，到账核对用',
  `qr_code_url`  VARCHAR(500) NOT NULL,
  `card_id`      BIGINT UNSIGNED NULL COMMENT '到账后自动生成/关联的卡密',
  `created_at_ms` BIGINT NOT NULL,
  `expires_at_ms` BIGINT NOT NULL,
  `paid_at_ms`   BIGINT NULL,
  `paid_note`    VARCHAR(255) NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_remark` (`remark_code`),
  KEY `idx_account_status` (`account_id`,`status`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='原版：扫码购买 + 备注码 + 到账进卡包';

-- ---------------------------------------------------------------- 下载配额
CREATE TABLE IF NOT EXISTS `douy_downloads` (
  `id`         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `card_id`    BIGINT UNSIGNED NOT NULL,
  `account_id` BIGINT UNSIGNED NULL,
  `device_id`  CHAR(40)     NOT NULL,
  `day_key`    DATE         NOT NULL,
  `count`      INT UNSIGNED NOT NULL DEFAULT 0,
  `updated_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_card_day` (`card_id`,`day_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='每张卡每天 5 次下载';

CREATE TABLE IF NOT EXISTS `douy_download_tokens` (
  `token`        CHAR(64)     NOT NULL,
  `version_code` INT UNSIGNED NOT NULL,
  `card_id`      BIGINT UNSIGNED NOT NULL,
  `device_id`    CHAR(40)     NOT NULL,
  `sha256`       CHAR(64)     NOT NULL,
  `created_at_ms` BIGINT NOT NULL,
  `expires_at_ms` BIGINT NOT NULL,
  `used`         TINYINT(1) NOT NULL DEFAULT 0,
  PRIMARY KEY (`token`),
  KEY `idx_device` (`device_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------- 插件版本
CREATE TABLE IF NOT EXISTS `douy_updates` (
  `id`            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `product`       VARCHAR(64)  NOT NULL DEFAULT 'DOUY',
  `plugin_id`     VARCHAR(64)  NOT NULL DEFAULT 'douy-ios-hook',
  `channel`       VARCHAR(32)  NOT NULL DEFAULT 'stable',
  `version_code`  INT UNSIGNED NOT NULL COMMENT '构建序号（必须递增）',
  `version_name`  VARCHAR(32)  NOT NULL,
  `min_ios`       VARCHAR(16)  NOT NULL DEFAULT '14.0',
  `size`          BIGINT UNSIGNED NOT NULL,
  `sha256`        CHAR(64)     NOT NULL,
  `file_path`     VARCHAR(255) NOT NULL COMMENT '相对 keys/../storage/updates 的路径',
  `changelog`     TEXT NULL,
  `release_tag`   VARCHAR(64) NULL COMMENT '如 release-59-<sha>',
  `generation`    INT UNSIGNED NOT NULL DEFAULT 0,
  `force_update`  TINYINT(1) NOT NULL DEFAULT 0,
  `active`        TINYINT(1) NOT NULL DEFAULT 1,
  `created_at`    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_version` (`channel`,`version_code`),
  KEY `idx_lookup` (`product`,`plugin_id`,`channel`,`active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='原版：/api/ios/update/check + download';

-- ---------------------------------------------------------------- 签名密钥
CREATE TABLE IF NOT EXISTS `douy_server_keys` (
  `kid`          VARCHAR(32) NOT NULL COMMENT 'ec-p256-1 / ed25519-1',
  `alg`          VARCHAR(24) NOT NULL COMMENT 'ES256 / Ed25519',
  `public_key`   TEXT NOT NULL COMMENT 'base64(PEM 或裸公钥)',
  `private_path` VARCHAR(255) NOT NULL COMMENT '私钥文件路径（放在 webroot 之外）',
  `active`       TINYINT(1) NOT NULL DEFAULT 1,
  `created_at`   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`kid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------- 审计
CREATE TABLE IF NOT EXISTS `douy_audit_log` (
  `id`         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `ts_ms`      BIGINT NOT NULL,
  `event`      VARCHAR(48) NOT NULL,
  `account_id` BIGINT UNSIGNED NULL,
  `device_id`  CHAR(40) NULL,
  `card_id`    BIGINT UNSIGNED NULL,
  `ip`         VARCHAR(45) NULL,
  `detail`     TEXT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_ts` (`ts_ms`),
  KEY `idx_event` (`event`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

SET FOREIGN_KEY_CHECKS = 1;

-- ---------------------------------------------------------------- 初始数据
INSERT INTO `douy_products` (`software_id`,`name`)
VALUES ('douy_ios_injection','兜鱼 iOS 注入插件')
ON DUPLICATE KEY UPDATE `name`=VALUES(`name`);

INSERT INTO `douy_plans` (`software_id`,`title`,`days_valid`,`price`,`qr_code_url`,`recommend`,`sort_order`,`active`)
SELECT 'douy_ios_injection','30 天',30,68.00,'https://example.com/qr/30.png',1,10,1 FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM `douy_plans` WHERE `software_id`='douy_ios_injection' AND `days_valid`=30);

INSERT INTO `douy_plans` (`software_id`,`title`,`days_valid`,`price`,`qr_code_url`,`recommend`,`sort_order`,`active`)
SELECT 'douy_ios_injection','90 天',90,158.00,'https://example.com/qr/90.png',0,20,1 FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM `douy_plans` WHERE `software_id`='douy_ios_injection' AND `days_valid`=90);

-- ---------------------------------------------------------------- 频率限制桶
CREATE TABLE IF NOT EXISTS `douy_rate` (
  `bucket`       VARCHAR(120) NOT NULL,
  `window_start` BIGINT       NOT NULL,
  `counter`      INT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (`bucket`,`window_start`),
  KEY `idx_window` (`window_start`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='简单滑动窗口计数（注册/登录限流）';
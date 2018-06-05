ALTER TABLE `feeds`
  ADD `digest_enabled` tinyint(1) UNSIGNED NOT NULL DEFAULT 0 AFTER `enabled`,
  ADD `digest_limit` tinyint UNSIGNED NOT NULL DEFAULT 5 AFTER `digest_enabled`,
  ADD `digest_signature` varchar(100) AFTER `digest_limit`;


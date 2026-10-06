-- Parma Ham purge procedures for the HammerDB TPROC-C schema (MySQL).
--
-- HammerDB inserts into orders, order_line and history forever (new_order
-- rows are consumed by the delivery transaction). To keep the database at a
-- stable size we delete rows that were added more than N hours ago.
--
-- To avoid scanning large tables, every purge run records a watermark: the
-- current d_next_o_id of every district and the current max history id.
-- A later run picks the newest watermark that is older than the retention
-- period and deletes everything below it, using primary key ranges only.
--
--  * orders/order_line: only o_id > 3000 is deleted, so the 3000 orders per
--    district created by the initial load (one per customer) remain and the
--    order-status transaction always finds an order for every customer.
--    Orders still waiting for delivery (present in new_order) are never
--    deleted.
--  * history is never read by the benchmark, so all old rows are deleted.

CREATE TABLE IF NOT EXISTS parmaham_purge_mark (
  mark_ts     DATETIME NOT NULL,
  d_w_id      INT NOT NULL,
  d_id        INT NOT NULL,
  next_o_id   INT NOT NULL,
  PRIMARY KEY (mark_ts, d_w_id, d_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS parmaham_purge_hist_mark (
  mark_ts     DATETIME NOT NULL,
  max_id      BIGINT NOT NULL,
  PRIMARY KEY (mark_ts)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS parmaham_purge_log (
  id                 BIGINT NOT NULL AUTO_INCREMENT,
  started_at         DATETIME(3) NOT NULL,
  finished_at        DATETIME(3) NULL,
  retention_hours    INT NOT NULL,
  watermark_ts       DATETIME NULL,
  orders_deleted     BIGINT NOT NULL DEFAULT 0,
  order_line_deleted BIGINT NOT NULL DEFAULT 0,
  history_deleted    BIGINT NOT NULL DEFAULT 0,
  note               VARCHAR(255) NULL,
  PRIMARY KEY (id)
) ENGINE=InnoDB;

DROP PROCEDURE IF EXISTS parmaham_purge_mark;
DROP PROCEDURE IF EXISTS parmaham_purge;

DELIMITER //

-- Record a watermark for "now".
CREATE PROCEDURE parmaham_purge_mark()
BEGIN
  DECLARE ts DATETIME DEFAULT NOW();
  INSERT IGNORE INTO parmaham_purge_mark (mark_ts, d_w_id, d_id, next_o_id)
    SELECT ts, d_w_id, d_id, d_next_o_id FROM district;
  INSERT IGNORE INTO parmaham_purge_hist_mark (mark_ts, max_id)
    SELECT ts, COALESCE(MAX(id), 0) FROM history;
  COMMIT;
END//

-- Record a watermark, then delete everything older than retention_hours.
-- batch_orders: number of orders deleted per transaction (per district).
CREATE PROCEDURE parmaham_purge(IN retention_hours INT, IN batch_orders INT)
BEGIN
  DECLARE done INT DEFAULT 0;
  DECLARE v_w, v_d, v_next, v_lo, v_hi, v_to INT;
  DECLARE v_mark DATETIME;
  DECLARE v_hlo, v_hhi, v_hto BIGINT;
  DECLARE v_log BIGINT;
  DECLARE n_o, n_ol, n_h BIGINT DEFAULT 0;
  DECLARE cur CURSOR FOR
    SELECT d_w_id, d_id, next_o_id FROM parmaham_purge_mark WHERE mark_ts = v_mark;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

  INSERT INTO parmaham_purge_log (started_at, retention_hours) VALUES (NOW(3), retention_hours);
  SET v_log = LAST_INSERT_ID();
  COMMIT;

  CALL parmaham_purge_mark();

  SELECT MAX(mark_ts) INTO v_mark FROM parmaham_purge_mark
   WHERE mark_ts <= NOW() - INTERVAL retention_hours HOUR;

  IF v_mark IS NULL THEN
    UPDATE parmaham_purge_log SET finished_at = NOW(3),
           note = 'no watermark older than retention period yet'
     WHERE id = v_log;
    COMMIT;
  ELSE
    -- orders and order_line, district by district, in small transactions
    OPEN cur;
    district_loop: LOOP
      SET done = 0;
      FETCH cur INTO v_w, v_d, v_next;
      IF done THEN LEAVE district_loop; END IF;

      SET v_lo = NULL;
      SELECT MIN(o_id) INTO v_lo FROM orders
       WHERE o_w_id = v_w AND o_d_id = v_d AND o_id > 3000;
      SET done = 0;
      SELECT COALESCE(MIN(no_o_id), v_next) - 1 INTO v_hi FROM new_order
       WHERE no_w_id = v_w AND no_d_id = v_d;
      SET done = 0;
      SET v_hi = LEAST(v_hi, v_next - 1);

      WHILE v_lo IS NOT NULL AND v_lo <= v_hi DO
        SET v_to = LEAST(v_hi, v_lo + batch_orders - 1);
        DELETE FROM order_line
         WHERE ol_w_id = v_w AND ol_d_id = v_d AND ol_o_id BETWEEN v_lo AND v_to;
        SET n_ol = n_ol + ROW_COUNT();
        DELETE FROM orders
         WHERE o_w_id = v_w AND o_d_id = v_d AND o_id BETWEEN v_lo AND v_to;
        SET n_o = n_o + ROW_COUNT();
        COMMIT;
        SET v_lo = v_to + 1;
      END WHILE;
    END LOOP;
    CLOSE cur;

    -- history, by primary key range
    SELECT max_id INTO v_hhi FROM parmaham_purge_hist_mark WHERE mark_ts = v_mark;
    SELECT MIN(id) INTO v_hlo FROM history;
    SET done = 0;
    WHILE v_hlo IS NOT NULL AND v_hhi IS NOT NULL AND v_hlo <= v_hhi DO
      SET v_hto = LEAST(v_hhi, v_hlo + batch_orders * 10 - 1);
      DELETE FROM history WHERE id BETWEEN v_hlo AND v_hto;
      SET n_h = n_h + ROW_COUNT();
      COMMIT;
      SET v_hlo = v_hto + 1;
    END WHILE;

    -- watermarks at or before the one just used are no longer needed
    DELETE FROM parmaham_purge_mark WHERE mark_ts < v_mark;
    DELETE FROM parmaham_purge_hist_mark WHERE mark_ts < v_mark;
    DELETE FROM parmaham_purge_log WHERE started_at < NOW() - INTERVAL 30 DAY;

    UPDATE parmaham_purge_log SET finished_at = NOW(3), watermark_ts = v_mark,
           orders_deleted = n_o, order_line_deleted = n_ol, history_deleted = n_h
     WHERE id = v_log;
    COMMIT;
  END IF;

  SELECT v_mark AS watermark, n_o AS orders_deleted,
         n_ol AS order_line_deleted, n_h AS history_deleted;
END//

DELIMITER ;

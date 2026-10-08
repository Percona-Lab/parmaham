-- Parma Ham purge procedures for the HammerDB TPROC-C schema (PostgreSQL).
-- The same method as mysql/lib/purge.sql:
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
--  * history is never read by the benchmark, so all old rows are deleted
--    (history.id is added by database-generate.sh).
--
-- The procedures commit after every batch, so they must be CALLed outside
-- an explicit transaction. Dead rows are reclaimed by autovacuum.

SET client_min_messages = warning;

CREATE TABLE IF NOT EXISTS parmaham_purge_mark (
  mark_ts     TIMESTAMPTZ NOT NULL,
  d_w_id      INT NOT NULL,
  d_id        INT NOT NULL,
  next_o_id   INT NOT NULL,
  PRIMARY KEY (mark_ts, d_w_id, d_id)
);

CREATE TABLE IF NOT EXISTS parmaham_purge_hist_mark (
  mark_ts     TIMESTAMPTZ NOT NULL PRIMARY KEY,
  max_id      BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS parmaham_purge_log (
  id                 BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  started_at         TIMESTAMPTZ(3) NOT NULL,
  finished_at        TIMESTAMPTZ(3) NULL,
  retention_hours    INT NOT NULL,
  watermark_ts       TIMESTAMPTZ NULL,
  orders_deleted     BIGINT NOT NULL DEFAULT 0,
  order_line_deleted BIGINT NOT NULL DEFAULT 0,
  history_deleted    BIGINT NOT NULL DEFAULT 0,
  note               VARCHAR(255) NULL
);

-- Record a watermark for "now".
CREATE OR REPLACE PROCEDURE parmaham_purge_mark()
LANGUAGE plpgsql AS $$
DECLARE
  ts TIMESTAMPTZ := date_trunc('second', clock_timestamp());
BEGIN
  INSERT INTO parmaham_purge_mark (mark_ts, d_w_id, d_id, next_o_id)
    SELECT ts, d_w_id, d_id, d_next_o_id FROM district
    ON CONFLICT DO NOTHING;
  INSERT INTO parmaham_purge_hist_mark (mark_ts, max_id)
    SELECT ts, COALESCE(MAX(id), 0) FROM history
    ON CONFLICT DO NOTHING;
  COMMIT;
END $$;

-- Record a watermark, then delete everything older than retention_hours.
-- batch_orders: number of orders deleted per transaction (per district).
CREATE OR REPLACE PROCEDURE parmaham_purge(retention_hours INT, batch_orders INT)
LANGUAGE plpgsql AS $$
DECLARE
  r       RECORD;
  v_mark  TIMESTAMPTZ;
  v_lo    INT; v_hi INT; v_to INT;
  v_hlo   BIGINT; v_hhi BIGINT; v_hto BIGINT;
  v_log   BIGINT;
  v_n     BIGINT;
  n_o     BIGINT := 0; n_ol BIGINT := 0; n_h BIGINT := 0;
BEGIN
  INSERT INTO parmaham_purge_log (started_at, retention_hours)
    VALUES (clock_timestamp(), retention_hours) RETURNING id INTO v_log;
  COMMIT;

  CALL parmaham_purge_mark();

  SELECT MAX(mark_ts) INTO v_mark FROM parmaham_purge_mark
   WHERE mark_ts <= clock_timestamp() - make_interval(hours => retention_hours);

  IF v_mark IS NULL THEN
    UPDATE parmaham_purge_log SET finished_at = clock_timestamp(),
           note = 'no watermark older than retention period yet'
     WHERE id = v_log;
    COMMIT;
    RAISE NOTICE 'no watermark older than % hours yet', retention_hours;
    RETURN;
  END IF;

  -- orders and order_line, district by district, in small transactions
  FOR r IN SELECT d_w_id, d_id, next_o_id FROM parmaham_purge_mark
            WHERE mark_ts = v_mark ORDER BY d_w_id, d_id LOOP
    SELECT MIN(o_id) INTO v_lo FROM orders
     WHERE o_w_id = r.d_w_id AND o_d_id = r.d_id AND o_id > 3000;
    SELECT COALESCE(MIN(no_o_id), r.next_o_id) - 1 INTO v_hi FROM new_order
     WHERE no_w_id = r.d_w_id AND no_d_id = r.d_id;
    v_hi := LEAST(v_hi, r.next_o_id - 1);

    WHILE v_lo IS NOT NULL AND v_lo <= v_hi LOOP
      v_to := LEAST(v_hi, v_lo + batch_orders - 1);
      DELETE FROM order_line
       WHERE ol_w_id = r.d_w_id AND ol_d_id = r.d_id AND ol_o_id BETWEEN v_lo AND v_to;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      n_ol := n_ol + v_n;
      DELETE FROM orders
       WHERE o_w_id = r.d_w_id AND o_d_id = r.d_id AND o_id BETWEEN v_lo AND v_to;
      GET DIAGNOSTICS v_n = ROW_COUNT;
      n_o := n_o + v_n;
      COMMIT;
      v_lo := v_to + 1;
    END LOOP;
  END LOOP;

  -- history, by primary key range
  SELECT max_id INTO v_hhi FROM parmaham_purge_hist_mark WHERE mark_ts = v_mark;
  SELECT MIN(id) INTO v_hlo FROM history;
  WHILE v_hlo IS NOT NULL AND v_hhi IS NOT NULL AND v_hlo <= v_hhi LOOP
    v_hto := LEAST(v_hhi, v_hlo + batch_orders * 10 - 1);
    DELETE FROM history WHERE id BETWEEN v_hlo AND v_hto;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    n_h := n_h + v_n;
    COMMIT;
    v_hlo := v_hto + 1;
  END LOOP;

  -- watermarks at or before the one just used are no longer needed
  DELETE FROM parmaham_purge_mark WHERE mark_ts < v_mark;
  DELETE FROM parmaham_purge_hist_mark WHERE mark_ts < v_mark;
  DELETE FROM parmaham_purge_log WHERE started_at < clock_timestamp() - INTERVAL '30 days';

  UPDATE parmaham_purge_log SET finished_at = clock_timestamp(), watermark_ts = v_mark,
         orders_deleted = n_o, order_line_deleted = n_ol, history_deleted = n_h
   WHERE id = v_log;
  COMMIT;
  RAISE NOTICE 'watermark %: deleted % orders, % order lines, % history rows',
    v_mark, n_o, n_ol, n_h;
END $$;

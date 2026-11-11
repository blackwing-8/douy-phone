<?php
/**
 * PDO 小封装（无 ORM，语句全部参数化）
 */
class Db
{
    /** @var PDO */
    private $pdo;
    /** @var array */
    private $cfg;

    public function __construct(array $cfg)
    {
        $this->cfg = $cfg;
        $options = [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES   => false,
        ];
        if (isset($cfg['options']) && is_array($cfg['options'])) {
            $options = $cfg['options'] + $options;
        }
        $this->pdo = new PDO($cfg['dsn'], $cfg['user'], $cfg['password'], $options);
    }

    public function pdo()
    {
        return $this->pdo;
    }

    public function q($sql, array $params = [])
    {
        $stmt = $this->pdo->prepare($sql);
        $stmt->execute($params);
        return $stmt;
    }

    public function one($sql, array $params = [])
    {
        $row = $this->q($sql, $params)->fetch();
        return $row === false ? null : $row;
    }

    public function all($sql, array $params = [])
    {
        return $this->q($sql, $params)->fetchAll();
    }

    public function scalar($sql, array $params = [])
    {
        $v = $this->q($sql, $params)->fetchColumn();
        return $v === false ? null : $v;
    }

    public function insert($sql, array $params = [])
    {
        $this->q($sql, $params);
        return (int)$this->pdo->lastInsertId();
    }

    public function exec($sql, array $params = [])
    {
        return $this->q($sql, $params)->rowCount();
    }

    public function begin()
    {
        if (!$this->pdo->inTransaction()) {
            $this->pdo->beginTransaction();
        }
    }

    public function commit()
    {
        if ($this->pdo->inTransaction()) {
            $this->pdo->commit();
        }
    }

    public function rollback()
    {
        if ($this->pdo->inTransaction()) {
            $this->pdo->rollBack();
        }
    }

    /** 事务包裹：fn(Db $db) 抛异常则回滚 */
    public function tx(callable $fn)
    {
        $this->begin();
        try {
            $result = $fn($this);
            $this->commit();
            return $result;
        } catch (Throwable $e) {
            $this->rollback();
            throw $e;
        }
    }

    public function audit($event, array $ctx, array $detail = [])
    {
        $this->q(
            'INSERT INTO douy_audit_log (ts_ms, event, account_id, device_id, card_id, ip, detail)
             VALUES (?,?,?,?,?,?,?)',
            [
                now_ms(),
                $event,
                isset($ctx['account_id']) ? $ctx['account_id'] : null,
                isset($ctx['device_id']) ? $ctx['device_id'] : null,
                isset($ctx['card_id']) ? $ctx['card_id'] : null,
                isset($ctx['ip']) ? $ctx['ip'] : null,
                $detail ? json_encode($detail, JSON_UNESCAPED_UNICODE) : null,
            ]
        );
    }
}

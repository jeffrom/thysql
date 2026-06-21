# theyql

tql -u root -h 127.0.0.1 -p

## dependencies

<!-- zig 0.15.2 -->
zig 0.16 should be good now

## misc

```sql
select concat('line1', char(10), 'line2') as text_value, cast(unhex('0001FF') as binary) as binary_value;
select concat('safe ', '東京', char(9), 'end') as mixed;
```

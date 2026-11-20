import pytest

from app.db import timescale


def test_policy_sql_has_both_api_generations_and_values():
    sql = "\n".join(timescale.policy_sql(7, 90, 30))
    assert "add_columnstore_policy('sensor_timeseries', after => INTERVAL '7 days')" in sql
    assert "add_compression_policy('sensor_timeseries', compress_after => INTERVAL '7 days')" in sql
    assert "add_retention_policy('sensor_timeseries', drop_after => INTERVAL '90 days')" in sql
    assert "add_retention_policy('skeleton_frames', drop_after => INTERVAL '30 days')" in sql
    # re-apply = remove first (idempotent sync on every start)
    assert sql.count("remove_retention_policy(") == 2


@pytest.mark.parametrize("bad", [0, -1, "7; DROP TABLE users"])
def test_policy_sql_rejects_bad_day_values(bad):
    with pytest.raises(ValueError):
        timescale.policy_sql(bad, 90, 30)


def test_segmentby_matches_spec():
    assert timescale.SENSOR.segmentby == "set_id, channel"
    assert timescale.SKELETON.segmentby == "set_id"

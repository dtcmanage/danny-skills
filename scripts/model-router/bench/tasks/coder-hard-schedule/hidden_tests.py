from copy import deepcopy
from answer import minimum_slots
def test_dependencies_capacity_and_optimum():
    jobs = [dict(id='a', weight=2, deps=[]), dict(id='b', weight=2, deps=[]),
            dict(id='c', weight=1, deps=['a']), dict(id='d', weight=1, deps=['b'])]
    before = deepcopy(jobs)
    assert minimum_slots(jobs, 3) == 3
    assert jobs == before
    assert minimum_slots(jobs, 4) == 2
def test_empty_and_impossible():
    assert minimum_slots([], 1) == 0
    assert minimum_slots([dict(id='a', weight=5, deps=[])], 4) is None
    assert minimum_slots([dict(id='a', weight=1, deps=['b']), dict(id='b', weight=1, deps=['a'])], 3) is None
def test_critical_chain_and_parallel_work():
    jobs = [dict(id='a', weight=2, deps=[]), dict(id='b', weight=2, deps=['a']),
            dict(id='c', weight=2, deps=['b'])] + [dict(id=str(i), weight=1, deps=[]) for i in range(3)]
    assert minimum_slots(jobs, 3) == 3
def test_first_fit_counterexample():
    jobs = [dict(id=i, weight=w, deps=[]) for i, w in enumerate([5, 2, 4, 1, 3, 5])]
    assert minimum_slots(jobs, 5) == 4
def test_capacity_and_dependencies_defeat_both_greedy_orders():
    # Optimum slots: {2}, {0}, {3}, {1,5}, {4}, {6}.
    jobs = [dict(id=i, weight=w, deps=d) for i, (w, d) in enumerate([
        (4, []), (3, [0]), (3, []), (4, [2]), (5, [0,2]), (2, [3]), (4, [4])])]
    assert minimum_slots(jobs, 5) == 6

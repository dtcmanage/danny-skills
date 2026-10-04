def minimum_slots(jobs, capacity):
    from collections import deque
    ids = {job['id']: i for i, job in enumerate(jobs)}
    deps = [sum(1 << ids[d] for d in job['deps']) for job in jobs]
    goal = (1 << len(jobs)) - 1
    queue, seen = deque([(0, 0)]), {0}
    while queue:
        done, slots = queue.popleft()
        if done == goal:
            return slots
        available = sum(1 << i for i, job in enumerate(jobs)
                        if not done & (1 << i) and deps[i] & done == deps[i])
        subset = available
        while subset:
            if sum(job['weight'] for i, job in enumerate(jobs) if subset & (1 << i)) <= capacity:
                next_done = done | subset
                if next_done not in seen:
                    seen.add(next_done)
                    queue.append((next_done, slots + 1))
            subset = (subset - 1) & available
    return None



#===========================================================================
# ISR/contexts/locks/preempt
#===========================================================================

# What's & Why atomic context?

https://lwn.net/Articles/274695/
https://www.kernel.org/doc/Documentation/locking/spinlocks.txt
http://www.linuxgrill.com/anonymous/fire/netfilter/kernel-hacking-HOWTO-2.html
```
There are two contexts (patterns of execution flow) in the Linux kernel: interrupt and user(space) contexts. User contexts are code which is entered from userspace: a system call. Unless the kernel code sleeps for some reason (explicitly allowing other code to run), no other user context will run on that CPU; this is the non-preemtive part. They are always associated with a particular process.

However, an interrupt can occur at any time, which halts the user context in its tracks and runs an interrupt context. This is not associated with any process; it is caused by a timer, an external hardware interrupt, or a bottom-half (bottom halves may be run off the timer or other interrupts, see below). When it is finished, the user context will resume. 
```

## what's special about interrupt context?

When your kernel module runs in ISR, a fundamental difference comparing to process-context
is regarding to sleep, the execution flow cannot sleep/suspend/scheduled
(though the work it's doing can be), it can only exit/finish the execution flow
by return from ISR.

## how to handle race-condition between ISR & user/process contexts?
ISR can interrupt process/user context, which gives the sleep/suspend/schedule capability
to the process/user context. but also introduces race-condition, how to protect data common
for both context?

disable interrupt is the obvious solution, local_irq_save() does this, but it's not
SMP safe. thus spinlock_irq_save() is invented

## here comes atomic context
spin_lock_irqsave() was invented, which introduces atomic context, it simply means
"un-breakable" or "un-interruptable" piece of execution flow, trigger by IRQ or
explicitly by aquiring a spinklock. actually it's also multi-CPU safe, only one CPU
can get the lock. Thus for SMP case, even in ISR you need to call  spin_lock_irqsave()
to prevent the same ISR running on another CPU touches the same data.


spin_lock() is designed for multi-CPU accessing safety w/o IRQ-disabling, thus
should only be used when no ISR is accessing the data. it's not the only way, but
it's the simplest implementation with minimal dependency on HW design(shared RAM is enough).
other mechanism would requires special HW&driver involved. (DMA Fence between GPU/CPU can be implemented in similar way)

When you aquired/holding a spinlock, sleep definitely would cause deadlock
because it gives other execution flow chances of trying to lock on the same spinlock,
it will busy-wait the lock forever spinning and the sleeping one never got a chance to wake-up.


we can see there is a functionc in_atomic() defined as following: 
```
/*
 * Are we running in atomic context?  WARNING: this macro cannot
 * always detect atomic context; in particular, it cannot know about
 * held spinlocks in non-preemptible kernels.  Thus it should not be
 * used in the general case to determine whether sleeping is possible.
 * Do not use in_atomic() in driver code.
 */
#define in_atomic()	(preempt_count() != 0)
```

## What is preemptive kernel ?

https://unix.stackexchange.com/questions/5180/what-is-the-difference-between-non-preemptive-preemptive-and-selective-preempti

On a preemptive kernel, a process A running in kernel mode can be replaced by another process B while in the middle of a kernel function,
typically by an IRQ happened during A running in kernel, and preemptive kernel decide to return to B from IRQ rather than back to A.

On a nonpreemptive kernel, process A would just have used all the processor time until he is finished or voluntarily decides to allow other processes to interrupt him (a planned process switch) by calling scheduler explicitly (like wait/sleep).

# voluntarily reschedule

related APIs are __set_current_state/schedule_timeout/wake_up_state

one example in dma_fence_default_wait(), it does following to sleep:

1.add signaling callback dma_fence_default_wait_cb();
2.__set_current_state(TASK_INTERRUPTIBLE) or __set_current_state(TASK_UNINTERRUPTIBLE);
3.timeout_left = schedule_timeout(timeout_left); 
4.check if we got what we wait, if not, goto 1 again.
5.when signaling callback dma_fence_default_wait_cb() was triggered on another execution flow,
  it calls wake_up_state(wait->task, TASK_NORMAL); to wake-up the waiting one

## what is preempt_count ?
https://www.informit.com/articles/article.aspx?p=414983&seqNum=2

Each task has a field, preempt_count, which marks whether the task is preemptible.
The count is incremented every time the task obtains a lock and decremented
whenever the task releases a lock.

## Mutex vs spinlock
https://stackoverflow.com/questions/5869825/when-should-one-use-a-spinlock-instead-of-mutex

mutex    : between process contexts only. may sleep. high-latency, for long-life lock like complex data structure.
spinlock : between any contexts. no sleep. low-latency. for short-life lock like few lines of code.


#===========================================================================
# RCU: Read, Copy, Update
#===========================================================================

https://dri.freedesktop.org/docs/drm/RCU/whatisRCU.html

unlike other locks which protects the data-structure with only on instance, RCU's
update operation would invent a new version of the data-structure, which co-exists
with the old-version until no-one is referecing the old-version. thus all readers are
guranteed to see old or new versions (at the same time) but not partially updated version.

suppose the update process is based on pointer-modification, then to achrive RCU when
an writer is trying to update a pointer P which has old value P1 to new value P2, 
we can set P to P2 directly by atomic update instruction (removal), but we need to know
if some reader is still referencing through P1, if so, we must defer the reclamation
operation to later time until no one is referencing through P1 anymore.

```
t0  |refP1-----------|
t1      |refP1---------------|
                             (reclaim P1)
t2         update(P,P2):
           t0/t1 is accessing P1
           P1 can only be reclaimed when t0/t1 quit refP1
           this can be done by calling synchronize_rcu() to wait        
```
the time between update(P,P2) and final reclamation of P1 is the "grace period"(extra-time
allowed before having to complete the final transaction), it seems to be not differencing
the reader of P1 with the readers not referencing P1, although it seems to be possible through rcu_dereference().

rcu_read_lock()/rcu_read_unlock(): MARK referencing period
rcu_dereference()                : dereference
synchronize_rcu() / call_rcu()   : wait/sync to the end of grace period
rcu_assign_pointer()             : update

# call_rcu

with synchronize_rcu(), the updater blocks until a grace period elapses.
This is quite simple, but in some cases one cannot afford to wait so
long -- there might be other high-priority work to be done.

In such cases, one uses call_rcu() rather than synchronize_rcu().
The call_rcu() API is as follows:

	void call_rcu(struct rcu_head * head,
		      void (*final_free_func)(struct rcu_head *head));

This function invokes func(head) after a grace period has elapsed.
This invocation might happen from either softirq or process context,
so the function is not permitted to block.

the rcu_head was used for 2 purposes:
1.it was passed to final_free_func to find the container to be reclaimed
2.by itself it's a linked-list node, thus used by call_rcu to
  group as many as callbacks happend before the end of next grace
  period. so they can be called in serials together.

rcu_head must be contained inside the container to be reclaimed, but it
was only used when the container has been removed by rcu_assign_pointer,
so usually it can be union-ed with other data field of container to save mem-footprint.

#===========================================================================
# dma_fence : seqno & context, seqno_fence
#===========================================================================

assigned to dma_fence in dma_fence_init(), and do not change. this seqno
should increasing monotonically for dma fence allocated within same context.

seqno is not absolute neccessary for representing dma fence, but it's easier
for implementing HW fence, HW only tracking the latest fence sequence number (seqno) it
has successfully signaled, and since fence sequence number is increasing monotonically,
thus the fence signal condition is smplified as:

   "latest processed sequence number" >= "sequence number of the testing fence"

(BTW this monotonically increasing would causes overflow bug after 584 years if HW
can process the buffer in 1G fps, so it's not a problem after all)

related API: dma_fence_later(f1, f2) return the later initialized un-signled fence
or NULL it was signaled.

A seqno_fence is a dma_fence which can complete in software when
enable_signaling is called, but it also completes when
(s32)((sync_buf)[seqno_ofs] - seqno) >= 0 is true, thus certain HW
can wait on the fence on its own (and also the data provider HW can
signal the fence on its own by simply write seqno), no need for SW intervention:

  fence = custom_get_fence(...);
  if ((seqno_fence = to_seqno_fence(fence)) != NULL) {
    dma_buf *fence_buf = seqno_fence->sync_buf;
    get_dma_buf(fence_buf);

    ... tell the hw the memory location to wait (seqno_ofs) ...
    custom_wait_on(fence_buf, seqno_fence->seqno_ofs, fence->seqno);
  } else {
    /* fall-back to sw sync * /
    fence_add_callback(fence, my_cb);
  }
 
#===========================================================================
# dma_fence : enable_signaling
#===========================================================================

dma fence may only be used between HWs w/o SW on CPU side involved, for example,
GPU produces fence for output buffer and this fence is passed back to GPU or another
piece of HW to use, SW on CPU doesn't care about the signaling at all.

SW on CPU side cares about signaling by calling dma_fence_wait/dma_fence_add_callback API
and to support the semantic behaviour of these API, additional work needs to be done
by the fence provider/generator, for example if it's GPU fence, the provider definitly
needs to setup interrupt or start a polling thread to enble the signaling. these
additional operations can be saved when SW on CPU dosen't care about signaling. 

thus enable_signaling() callback was invented to explicitly tell the fence provider
to setup signaling mechanism for SW. after this type of signaling is "enabled", the
under-lying fence provider is reponsible for calling dma_fence_signal() when it detects
fence signal by means of interrupt/polling.

we can see dma_fence provide a framework for fence driver, also with SW signaling/callback
implemented, but HW fence driver needs to customize it by install their own dma_fence_ops
in dma_fence_init.

dma_fence_wait
dma_fence_add_callback


# get/put/release/free

get/put : refcount
release : called when put reduces refcount to zero
          dma_fence_release() also check un-signaled fence
          and do the signal with fence->error set to -EDEADLK
free    : the final operation inside release, free the memory
          consider that someone may put dma_fence into another
          data structure(like list/tree), and protecting it with rcu.
          then when it was removed from that data structure, its
          reclamation should be done at grace period instead of
          directly, thus the kfree_rcu was used, which encode rcu offset to the
          base structure to be freed (thus default kfree on base
          structure can be called)



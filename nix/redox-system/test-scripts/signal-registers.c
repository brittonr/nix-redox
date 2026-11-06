#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <sched.h>

static volatile sig_atomic_t handled;
static int ready;
static int send_error;
static pthread_t main_thread;

static void handle_signal(int signal_number) {
    (void)signal_number;
    handled = 1;
}

static void *send_signal(void *argument) {
    int signal_number = *(int *)argument;
    while (!__atomic_load_n(&ready, __ATOMIC_ACQUIRE)) {
        sched_yield();
    }
    send_error = pthread_kill(main_thread, signal_number);
    if (send_error != 0) {
        handled = 1;
    }
    return NULL;
}

int main(void) {
    const uint64_t expected = UINT64_C(0x12345678abcdef00);
    int signals[] = { SIGUSR1, SIGRTMIN };
    main_thread = pthread_self();
    for (unsigned int i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i) {
        struct sigaction action = {0};
        action.sa_handler = handle_signal;
        if (sigemptyset(&action.sa_mask) != 0 ||
            sigaction(signals[i], &action, NULL) != 0) {
            perror("sigaction");
            return 1;
        }
        handled = 0;
        ready = 0;
        send_error = 0;
        pthread_t sender;
        if (pthread_create(&sender, NULL, send_signal, &signals[i]) != 0) {
            fputs("pthread_create failed\n", stderr);
            return 1;
        }
        uint64_t actual;
        __asm__ volatile (
            "movabs $0x12345678abcdef00, %%rcx\n\t"
            "movl $1, %[ready]\n\t"
            "movl $500000000, %%eax\n\t"
            "1: pause\n\t"
            "cmpl $0, %[handled]\n\t"
            "jne 2f\n\t"
            "decl %%eax\n\t"
            "jne 1b\n\t"
            "2: movq %%rcx, %[actual]\n\t"
            : [actual] "=m" (actual), [ready] "+m" (ready)
            : [handled] "m" (handled)
            : "rax", "rcx", "cc", "memory"
        );
        if (pthread_join(sender, NULL) != 0 || send_error != 0 || !handled ||
            actual != expected) {
            fprintf(stderr, "signal=%d handled=%ld send_error=%d rcx=%llx\n",
                signals[i], (long)handled, send_error, (unsigned long long)actual);
            return 1;
        }
    }
    puts("signal registers preserved");
    return 0;
}

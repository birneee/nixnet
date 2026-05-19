// PID 1 for named jails: blocks all signals and sleeps forever to keep the
// pid namespace alive until the jail is explicitly destroyed.
#include <signal.h>
#include <unistd.h>

int main(void) {
  sigset_t s;
  sigfillset(&s);
  sigprocmask(SIG_BLOCK, &s, 0);
  for (;;) pause();
}

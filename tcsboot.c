#ifndef _XOPEN_SOURCE
#define _XOPEN_SOURCE 500
#endif

#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif

#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE 1
#endif

#ifndef _BSD_SOURCE
#define _BSD_SOURCE 1
#endif

#ifndef _SVID_SOURCE
#define _SVID_SOURCE 1
#endif

#include <stdio.h>
#include <errno.h>
#include <syslog.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <features.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <signal.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/time.h>
#include "tcsboot.h"

/* This file is a part of tcsboot, the Fortian Inc. netbooting and deployment
   utility.

   This program is distributed in the hope that it will be useful, but WITHOUT
   ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
   FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
   more details.

   You should have received a copy of the GNU General Public License along with
   this program; if not, write to the Free Software Foundation, Inc., 51
   Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

   $Id: tcsboot.c,v 1.8 2017/09/27 00:04:00 bstern Exp $ */

volatile sig_atomic_t reread = 1; /* triggers reread of netboot.conf */
volatile sig_atomic_t die = 0; /* we got a TERM or we're in trouble */

/* Helper function to clear the struct hosts linked list. */
static void freehosts(struct hosts *h) {
    register struct hosts *i = h;

    while (i != NULL) {
        h = i->next;
        free(i);
        i = h;
    }
}

void hup(int signum) {
    if (signum == SIGHUP) {
        reread = 1;
    } else /* if (signal == SIG_TERM) */ {
        die = 1; /* We're done. */
    }

#if !(defined(__GLIBC__) && (__GLIBC__ >= 2))
    /* Old GNU C libraries require that the signal handler be reset. */
    if (signal(signum, hup) == SIG_ERR) {
        die = 1; /* We couldn't reset the signal handler. */
    }
#endif
}

int markup(struct hosts *h, const char *name) {
    int rv = 0;
    struct hosts *i = h;

    while (i != NULL) {
        if (!strcmp(i->name, name)) {
#ifdef DEBUG
            syslog(LOG_NOTICE, "Tagging node %s for netbooting", name);
#endif
            i->netboot = 1;
            rv++;
            break;
        } else {
            i = i->next;
        }
    }
    return rv;
}

int process(void) {
    struct hosts *iter, *h = NULL;
    FILE *f = fopen(HW_CONF, "r");
    int rv = 0;
    char line[BUFSIZ];
    char *idx;
    int i, t, ln = 0;
    char *mac, *ip, *name;
    char tn[] = DHCPD_CONF ".XXXXXX";

#ifdef DEBUG
    syslog(LOG_NOTICE, "Beginning function process");
#endif

    if (f == NULL) {
        rv = errno;
        syslog(LOG_ERR, "Couldn't open " HW_CONF ": %m");
        return rv;
    }
    do {
        idx = fgets(line, BUFSIZ, f);
        if (idx != NULL) {
            ln++;
            idx = strchr(line, '#');
            if (idx != NULL) *idx = 0;
            if ((line[0] == '\0') || (line[0] == '\n')) continue;
            i = 0;
            idx = strtok(line, ",");
            mac = ip = name = NULL;
            while ((idx != NULL) && (i++ < /* 6 */ 3)) {
                /* Actually, we don't want the first word anyway. */
                idx = strtok(NULL, ",");
                if (i == 1) mac = idx;
                else if (i == 2) ip = idx;
                else if (i == 3) name = idx;
            }
            if ((ip == NULL) || (mac == NULL) || (name == NULL)) {
                syslog(LOG_WARNING, "Skipping line %d of " HW_CONF
                    ": not enough commas", ln);
            } else {
#ifdef DEBUG
                syslog(LOG_NOTICE, "Identified system %s: %s/%s",
                    name, ip, mac);
#endif
                iter = malloc(sizeof (struct hosts) + strlen(name) + 1);
                if (iter == NULL) {
                    rv = errno;
                    syslog(LOG_ERR, "Couldn't allocate %lu bytes: %m",
                        sizeof (struct hosts) + strlen(name) + 1);
                    freehosts(h);
                    fclose(f);
                    return rv;
                }
                strcpy(iter->name, name);
                strcpy(iter->ip, ip);
                strcpy(iter->mac, mac);
                iter->next = h;
                iter->netboot = 0;
                h = iter;
            }
        } /* fgets != NULL */
    } while (!feof(f));
    fclose(f);

    f = fopen(NETBOOT_CONF, "r");
    if (f == NULL) {
        rv = errno;
        syslog(LOG_ERR, "Couldn't open " NETBOOT_CONF ": %m");
        freehosts(h);
        return rv;
    }
    fgets(line, BUFSIZ, f); /* skip this line */
    ln = 1;
    while (!feof(f) && ((fgets(line, BUFSIZ, f)) != NULL)) {
        ln++;
        idx = strchr(line, '#');
        if (idx != NULL) *idx = 0;
        if ((line[0] == '\0') || (line[0] == '\n')) continue;
        idx = strtok(line, ":,"); /* should be , but is : right now */
        if (idx == NULL) {
            syslog(LOG_WARNING, "Skipping line %d of " NETBOOT_CONF
                ": no host entry", ln);
        } else if (!markup(h, idx)) {
            syslog(LOG_WARNING, "Ignoring line %d of " NETBOOT_CONF
                ": no match for %s", ln, idx);
        }
    }
    fclose(f);

    f = fopen(DHCPD_CONF, "r");
    if (f == NULL) {
        rv = errno;
        syslog(LOG_ERR, "Couldn't open " DHCPD_CONF ": %m");
        freehosts(h);
        return rv;
    }
    t = mkstemp(tn);
    if (t < 0) {
        rv = errno;
        syslog(LOG_ERR, "Couldn't create temp file: %m");
        fclose(f);
        freehosts(h);
        return rv;
    }
    do {
        if (fgets(line, BUFSIZ, f) != NULL) {
            write(t, line, strlen(line));
            if (!strcmp(line, NOEDIT)) break;
        }
    } while (!feof(f));
    fclose(f);

    iter = h;
    while (iter != NULL) {
#ifdef DEBUG
        syslog(LOG_NOTICE, "Adding entry for %s: %s/%s (%u)",
            iter->name, iter->ip, iter->mac, iter->netboot);
#endif
        if (iter->netboot) {
            snprintf(line, BUFSIZ, "\t\thost %s {\n\t\t\thardware ethernet "
                "%s;\n\t\t\tfixed-address %s;\n\t\t}\n", iter->name, iter->mac,
                iter->ip);
        } else {
#ifdef UNKNOWN_GIVE_BOGUS_FILENAME
            snprintf(line, BUFSIZ, "\t\thost %s {\n\t\t\thardware ethernet "
                "%s;\n\t\t\tfixed-address %s;\n\t\t\tfilename \"%s\";\n\t\t}\n",
                iter->name, iter->mac, iter->ip, "/nosuchfile");
#else
# ifdef UNKNOWN_DENIED
            line[0] = 0;
# else
            snprintf(line, BUFSIZ, "\t\thost %s {\n\t\t\thardware ethernet "
                "%s;\n\t\t\tdeny booting;\n\t\t}\n", iter->name, iter->mac);
# endif
#endif
        }
        line[BUFSIZ - 1] = 0;
        if (write(t, line, strlen(line)) < 0) {
            rv = errno;
            syslog(LOG_ERR, "Couldn't write to temporary DHCPD config: %m");
            close(t);
            freehosts(h);
            return rv;
        }
        iter = iter->next;
    }
    if (write(t, "\t}\n}\n", 5) < 0) {
        rv = errno;
        syslog(LOG_ERR, "Couldn't write suffix to temp config: %m");
        close(t);
    } else if (close(t) < 0) {
        rv = errno;
        syslog(LOG_ERR, "Couldn't close temporary file: %m");
    } else if (rename(tn, DHCPD_CONF) < 0) {
        rv = errno;
        syslog(LOG_ERR,
            "Couldn't rename DHCP daemon configuration \"%s\" to \"%s\": %m",
            tn, DHCPD_CONF);
    } else if ((rv = system(RESTART) < 0)) {
        syslog(LOG_ERR, "Couldn't restart DHCPD: %m");
    } else if (rv) {
        syslog(LOG_WARNING, "DHCPD restart returned %d", rv);
    } else {
        syslog(LOG_INFO, "DHCPD restart was successful");
    }
    freehosts(h); /* Don't leak this list. */
    return rv;
}

int rewrite(int sock) {
    char buf[BUFSIZ];
    unsigned char nb;
    int had, want;
    FILE *f;
    char *idx;
    int ln = 0;
    int t = 0;
    int rv = 0;
    int found = 0;
    char *newstage = NULL;
    int got = 0;
    char tn[] = NETBOOT_CONF ".XXXXXX";
    char *name = NULL;

    if (read(sock, &nb, 1) < 0) {
        rv = errno;
        syslog(LOG_ERR, "Couldn't read from socket: %m");
        return rv;
    } else {
        want = nb;
        while (got < want) {
            had = read(sock, &buf[got], want - got);
#ifdef DEBUG
            if (had > 0) {
                buf[got + had] = 0;
            } else {
                buf[got] = 0;
            }
            syslog(LOG_NOTICE, "Stage 1) want: %i, got: %i, had: %i, buf: %s",
                want, got, had, buf);
#endif
            if (had < 0) {
                rv = errno;
                syslog(LOG_ERR, "Read failed %d bytes into packet: %m", got);
                return rv;
            } else {
                got += had;
            }
        }
        buf[got] = 0;
#ifdef DEBUG
        syslog(LOG_NOTICE, "Learnt nodename %s", buf);
#endif
        name = strdup(buf);
        if (name == NULL) {
            rv = errno;
            syslog(LOG_ERR, "Couldn't duplicate name: %m");
            return rv;
        }
    }

    if (read(sock, &nb, 1) < 0) {
        rv = errno;
        syslog(LOG_ERR, "Couldn't read second stage from socket: %m");
        free(name);
        return rv;
    } else if (nb) {
        want = nb;
        got = 0;
        while (got < want) {
            had = read(sock, &buf[got], want - got);
#ifdef DEBUG
            if (had > 0) {
                buf[got + had] = 0;
            } else {
                buf[got] = 0;
            }
            syslog(LOG_NOTICE, "Stage 2) want: %i, got: %i, had: %i, buf: %s",
                want, got, had, buf);
#endif
            if (had < 0) {
                rv = errno;
                syslog(LOG_ERR, "Reread failed %d bytes into packet: %m", got);
                free(name);
                return rv;
            } else {
                got += had;
            }
        }
        buf[got] = 0;
#ifdef DEBUG
        syslog(LOG_NOTICE, "Learnt nodename %s should go to state `%s'", name,
            buf);
#endif
        newstage = strdup(buf);
        if (newstage == NULL) {
            rv = errno;
            syslog(LOG_ERR, "Couldn't strdup stage: %m");
            free(name);
            return rv;
        }
    }

#ifdef DEBUG
    syslog(LOG_NOTICE, "newstage: %s; now hunting for %s in " NETBOOT_CONF,
        newstage, name);
#endif

    f = fopen(NETBOOT_CONF, "r");
    if (f == NULL) {
        rv = errno;
        syslog(LOG_ERR, "Couldn't read " NETBOOT_CONF ": %m");
    } else if ((t = mkstemp(tn)) < 0) {
        rv = errno;
        syslog(LOG_ERR, "Couldn't create temp file for netboot: %m");
    } else do {
        ln++;
        if (fgets(buf, BUFSIZ, f) != NULL) {
#ifdef DEBUG
            syslog(LOG_NOTICE, "Now on line %d of " NETBOOT_CONF, ln);
#endif
            idx = strchr(buf, '#');
            if (idx != NULL) {
                *idx = 0;
            }
            if ((buf[0] == '\0') || (buf[0] == '\n')) {
                continue;
            }
            idx = strchr(buf, ':');
            if (idx == NULL) {
                idx = strchr(buf, ',');
            }
            if (idx == NULL) {
                syslog(LOG_NOTICE, "Ignoring line %d of " NETBOOT_CONF, ln);
            } else if (newstage == NULL) {
                /* clang says this is still possible, so warn the user */
                syslog(LOG_ERR, "Can't find next stage");
                free(name);
                return rv;
            } else if ((ln >= 1) && (strstr(buf, name) != NULL)) {
#ifdef DEBUG
                syslog(LOG_NOTICE, "Found line with %s and newstage",
                    name, newstage);
#endif
                if (*newstage != '|') {
                    if ((write(t, name, strlen(name)) < 0) ||
                        (write(t, ":", 1) < 1) || /* XXX should be , */
                        (write(t, newstage, strlen(newstage)) < 0) ||
                        (write(t, "\n", 1) < 1)) {
                        rv = errno;
                        syslog(LOG_ERR, "Couldn't write '%s:%s' to %s: %m",
                            name, newstage, tn);
                        fclose(f);
                        close(t);
                        free(name);
                        free(newstage);
                        return rv;
                    } else {
                        syslog(LOG_NOTICE, "Changed %s to %s", name, newstage);
                        found++;
                        rv--; /* Don't relaunch dhcpd, though. */
                    }
                } else { /* No new stage to go to. */
                    syslog(LOG_NOTICE, "Removing %s from netbooting", name);
                    found++;
                }
            } else if (write(t, buf, strlen(buf)) < 0) {
                rv = errno;
                syslog(LOG_ERR, "Couldn't write `%s' to %s: %m", buf, tn);
                fclose(f);
                close(t);
                free(name);
                if (newstage != NULL) free(newstage);
                return rv;
            }
#ifdef DEBUG
        } else {
            syslog(LOG_NOTICE, "got NULL from fgets: %m");
#endif
        }
    } while ((rv <= 0) && !feof(f));
    if (!found) {
        syslog(LOG_WARNING, "Node `%s' is already not being netbooted", name);
    }
    if (newstage != NULL) free(newstage);
    free(name);
    fclose(f);
    if (close(t) < 0) {
        rv = errno;
        syslog(LOG_ERR, "Couldn't close temporary " NETBOOT_CONF ": %m");
    }
    if (rv <= 0) {
        if (rename(tn, NETBOOT_CONF) < 0) {
            rv = errno;
            syslog(LOG_ERR, "Couldn't rename %s to " NETBOOT_CONF ": %m", tn);
        }
    }
#ifdef DEBUG
    syslog(LOG_NOTICE, "Rewrite end; rv: %i, found: %i", rv, found);
#endif
    if (rv) return rv;
    else if (found) return 0;
    else return -1;
}

int main(int argc, char *argv[]) {
    int rv = 0;
    pid_t child;
    int sock = -1;
    struct sockaddr_in sin;
    int conn;
    fd_set fs;
    struct timeval tv;
    /* struct linger l = { 0, 0 };
    int one = 1; */
    int i;

    sin.sin_family = AF_INET;
    sin.sin_port = htons(PORTNO);
    sin.sin_addr.s_addr = INADDR_ANY;

    openlog(PROGRAM ": ", LOG_PID|LOG_ODELAY, FACILITY);
    if (chdir("/") < 0) {
        rv = errno;
        perror("Couldn't cd /");
        return rv;
    } else if (close(0) < 0) {
        rv = errno;
        perror("Couldn't close standard input");
        return rv;
    } else if (close(1) < 0) {
        rv = errno;
        perror("Couldn't close standard output");
        return rv;
    } else if (close(2) < 0) {
        syslog(LOG_ERR, "Couldn't close standard error: %m");
        closelog();
        return errno; 
    } else if ((child = fork()) < 0) {
        syslog(LOG_ERR, "Couldn't fork: %m");
        closelog();
        return errno; 
    } else if (child) {
        return 0;
    } else if ((sock = socket(AF_INET, SOCK_STREAM, 0)) < 0) {
        rv = errno;
        syslog(LOG_ERR, "Couldn't open socket: %m");
    } else if (bind(sock, (struct sockaddr *)&sin,
        sizeof (struct sockaddr_in)) < 0) {
        rv = errno;
        syslog(LOG_ERR, "Couldn't bind socket: %m");
    } else if (listen(sock, LISTENLEN) < 0) {
        rv = errno;
        syslog(LOG_ERR, "Couldn't listen to socket: %m");
    } else if (signal(SIGHUP, hup) == SIG_ERR) { /* We're the child process. */
        rv = errno;
        syslog(LOG_ERR, "Couldn't register signal handler for HUP: %m");
    } else if (signal(SIGTERM, hup) == SIG_ERR) {
        rv = errno;
        syslog(LOG_ERR, "Couldn't register signal handler for TERM: %m");
    } else while (!die) {
        FD_ZERO(&fs);
        FD_SET(sock, &fs);
        tv.tv_sec = 0;
        tv.tv_usec = 500; /* 0.5 secs between sweeps */

        if (reread) {
            syslog(LOG_INFO, "Rereading...");
            process();
            reread = 0;
        }
        i = select(sock + 1, &fs, NULL, NULL, &tv);
        if ((i < 0) && (errno != EINTR)) {
            rv = errno;
            syslog(LOG_WARNING, "Couldn't select: %m");
            break;
        } else if (i > 0) {
            if ((conn = accept(sock, NULL, NULL)) < 0) {
                if (errno != EINTR) syslog(LOG_WARNING, "Couldn't accept: %m");
            }
            if (conn >= 0) {
                if (!rewrite(conn)) reread = 1;
                shutdown(conn, SHUT_RDWR);
                close(conn);
            }
        }
    }
    syslog(LOG_NOTICE, "Exiting...");
    if (sock >= 0) {
        if (shutdown(sock, SHUT_RDWR) < 0) {
            syslog(LOG_WARNING, "Couldn't shutdown socket: %m");
        }
        if (close(sock) < 0) {
            rv = errno;
            syslog(LOG_WARNING, "Couldn't close socket: %m");
        }
    }
    return rv;
}

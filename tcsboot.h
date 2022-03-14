#ifndef __TCSBOOT_H
#define __TCSBOOT_H

/* This file is a part of tcsboot, the Fortian Inc. netbooting and deployment
   utility.

   This program is distributed in the hope that it will be useful, but WITHOUT
   ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
   FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
   more details.

   You should have received a copy of the GNU General Public License along with
   this program; if not, write to the Free Software Foundation, Inc., 51
   Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

   $Id: tcsboot.h,v 1.6 2017/09/27 00:04:01 bstern Exp $ */

/* What should we identify ourselves as in syslog? */
#define PROGRAM "tcsboot"

/* What facility should we syslog at? */
#define FACILITY LOG_DAEMON

/* What TCP port should tcsboot listen on for systems to phone home and let us
    know that installation was successful and they don't need to be netbooted
    again?  This MUST match the port number in netboot.pl to work properly. */
#define PORTNO 31678

/* Where is the TCS- and tcsboot-generated netboot.conf stored?
    This MUST be the directory that is NFS exported to serve as the netbooted
    system's / (and must be specified in the dhcpd.conf). */
#define NETBOOT_CONF "/export/miniroot/netboot.conf"

/* Where is the TCS-generated hw.config file stored? */
#define HW_CONF "/mantis/hw.config"

/* How do we restart dhcpd?  Note that Fedora Core 3's stock init script appears
    to be totally broken.  The accompanying init script has been tested and
    worked for me. */
#define RESTART "/home/tcsboot/dhcpd restart"
/* Alternatively, try using the service command (suggested by M. Saverino). */
/* #define RESTART "/sbin/service dhcpd --full-restart > /etc/dhcpd.out" */

/* Where is your dhcpd.conf stored? */
#define DHCPD_CONF "/etc/dhcpd.conf"

/* Indicates where we can start to rewrite the dhcpd.conf. */
#define NOEDIT "# DO NOT EDIT BELOW THIS LINE\n"

/* Define this to grant leases to non-netbooting hosts but point them
    to a nonexistent boot image.  This will sometimes allow a faster
    netboot failure. */
#define UNKNOWN_GIVE_BOGUS_FILENAME

/* If your dhcpd.conf has "deny unknown-clients;" as it ought, define the next
    line to leave out non-netbooting hosts from the dhcpd.conf (and thereby
    make it easier to read for humans).
    NOTE: This is only effective if UNKNOWN_GIVE_BOGUS_FILENAME is undefined.
 */
#define UNKNOWN_DENIED

/* How much of a backoff should listen use?  Under Linux, values higher than 5
    are respected, and in fact, seem to be required for Fedora Core 3's
    2.6.10-1.770_FC3.  Increase this number if tcsboot hangs on a read(2)
    system call.  Added by M. Saverino. */
#define LISTENLEN 72

/* You should not normally need to edit anything below this line. */

/* Hold interesting information from the TCS hw.config file.
    It is currently a simple linked list, but since it is only expected to hold
    about 100 entries, the linear search is adequate. */
struct hosts {
    struct hosts *next;
    int netboot;
    char ip[16]; /* "123.567.9ab.def" */
    char mac[18]; /* 12:45:78:ab:de:01" */
    char name[0]; /* We don't know how long this needs to be at decl time. */
};

/* Signal handler for HUP and TERM */
void hup(int signum);

/* Marks hosts for netbooting. */
int markup(struct hosts *h, const char *name);

/* Processes hw.config to learn about test nodes. */
int process(void);

/* Removes nodename from netboot.conf and triggers rewrite of dhcpd.conf. */
int rewrite(int sock);

#endif

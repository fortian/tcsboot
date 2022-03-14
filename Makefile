# $Id: Makefile,v 1.1.1.1 2007/10/26 04:38:25 bstern Exp $

.PHONY: all clean

CFLAGS=-Wall -Werror -O2

all: tcsboot

tcsboot.o: tcsboot.c tcsboot.h

clean:
	rm -f *.o tcsboot

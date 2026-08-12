/* Copyright (c) 2013, Christophe Fergeau <cfergeau@redhat.com>
 * 
 * The code contained in this file is free software; you can redistribute
 * it and/or modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either version
 * 2.1 of the License, or (at your option) any later version.
 *
 * This file is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this code; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 *
 * iTunes and iPod are trademarks of Apple
 *
 * This product is not supported/written/published by Apple!
 *
 */
#ifndef LIBGPOD_SYSLOG_H
#define LIBGPOD_SYSLOG_H

#include <glib.h>

G_BEGIN_DECLS

G_GNUC_INTERNAL void itdb_syslog (const char *format, ...);

G_END_DECLS

#endif

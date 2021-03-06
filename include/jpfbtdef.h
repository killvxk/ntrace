#pragma once

/*----------------------------------------------------------------------
 * Purpose:
 *		Common definitions shared among all subprojects.
 *
 * Copyright:
 *		Johannes Passing (johannes.passing@googlemail.com)
 */

#ifndef NT_SUCCESS
#define NT_SUCCESS(Status) ((NTSTATUS)(Status) >= 0)
#endif

#define STATUS_SUCCESS                   ((NTSTATUS)0x00000000L)
#define STATUS_UNSUCCESSFUL              ((NTSTATUS)0xC0000001L)
#define STATUS_NOT_IMPLEMENTED           ((NTSTATUS)0xC0000002L)
#define STATUS_OBJECT_NAME_COLLISION	 ((NTSTATUS)0xC0000035L)
#define STATUS_ALERTED                   ((NTSTATUS)0x00000101L)
#define STATUS_OBJECT_NAME_NOT_FOUND     ((NTSTATUS)0xC0000034L)
#define STATUS_BUFFER_TOO_SMALL          ((NTSTATUS)0xC0000023L)

#ifndef STATUS_INVALID_PARAMETER
	#define STATUS_INVALID_PARAMETER         ((NTSTATUS)0xC000000DL)
#endif

#ifndef ASSERT
	#define ASSERT _ASSERTE
#endif

#ifndef VERIFY
	#if defined(DBG) || defined( DBG )
		#define VERIFY ASSERT
	#else
		#define VERIFY( x ) ( VOID ) ( x )
	#endif
#endif

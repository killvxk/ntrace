#pragma once

/*----------------------------------------------------------------------
 * Purpose:
 *		Internal definitions.
 *
 * Copyright:
 *		Johannes Passing (johannes.passing@googlemail.com)
 */
#ifndef JPFBT_TARGET_USERMODE
	#define JPFBT_TARGET_USERMODE
#endif

#include <jpfsv.h>
#include <jpfbt.h>
#include <jpfbtdef.h>
#include <hashtable.h>
#include <crtdbg.h>

extern CRITICAL_SECTION JpfsvpDbghelpLock;

/*----------------------------------------------------------------------
 *
 * Lib initialization. For use by DllMain only.
 *
 */

BOOL JpfsvpInitializeLoadedContextsHashtable();
BOOL JpfsvpDeleteLoadedContextsHashtable();

/*----------------------------------------------------------------------
 *
 * Util routines.
 *
 */

PVOID JpfsvpAllocateHashtableMemory(
	__in SIZE_T Size 
	);

VOID JpfsvpFreeHashtableMemory(
	__in PVOID Mem
	);

/*++
	Routine Description:
		Parse an integer in the format
			hhhh (hexadecimal)
			0nddd (decimal)
			0xhhhh (hexadecimal)
	Parameters:
		Str		 - String to be parsed.
		StopChar - Character that stopped scan.
		Number	 - Result.
	Return Value:
		TRUE iff parsing succeeded.
--*/
BOOL JpfsvpParseInteger(
	__in PCWSTR Str,
	__out PWSTR *RemainingStr,
	__out PDWORD Number
	);

/*++
	Routine Description:
		Checks if a string consists of whitespace only.
--*/
BOOL JpfsvpIsWhitespaceOnly(
	__in PCWSTR String
	);


__inline BOOL JpfsvpIsCriticalSectionHeld(
	__in PCRITICAL_SECTION Cs
	)
{
#if DBG
	if ( TryEnterCriticalSection( Cs ) )
	{
		BOOL WasAlreadyHeld = Cs->RecursionCount > 1;
		
		LeaveCriticalSection( Cs );

		return WasAlreadyHeld;
	}
	else
	{
		return FALSE;
	}
#else
	UNREFERENCED_PARAMETER( Cs );
	return TRUE;
#endif
}

/*----------------------------------------------------------------------
 *
 * UM Patchability Inspection.
 *
 */

HRESULT JpfsvpIsProcedureHotpatchable(
	__in HANDLE Process,
	__in DWORD_PTR ProcAddress,
	__out PBOOL Hotpatchable
	);

HRESULT JpfsvpGetProcedurePaddingSize(
	__in HANDLE Process,
	__in DWORD_PTR ProcAddress,
	__out PUINT PaddingSize
	);

/*----------------------------------------------------------------------
 *
 * Event Processor.
 *
 */

typedef enum
{
	JpfsvFunctionEntryEventType,
	JpfsvFunctionExitEventType
} JPFSV_EVENT_TYPE;

typedef struct _JPFSV_EVENT_PROESSOR
{
	VOID ( *ProcessEvent ) (
		__in struct _JPFSV_EVENT_PROESSOR *This,
		__in JPFSV_EVENT_TYPE Type,
		__in DWORD ThreadId,
		__in DWORD ProcessId,
		__in JPFBT_PROCEDURE Procedure,
		__in PJPFBT_CONTEXT ThreadContext,
		__in PLARGE_INTEGER Timestamp
		);	

	VOID ( *Delete ) (
		__in struct _JPFSV_EVENT_PROESSOR *This
		);
} JPFSV_EVENT_PROESSOR, *PJPFSV_EVENT_PROESSOR;

HRESULT JpfsvpCreateDiagEventProcessor(
	__in CDIAG_SESSION_HANDLE DiagSession,
	__in JPFSV_HANDLE ContextHandle,
	__out PJPFSV_EVENT_PROESSOR *EvProc
	);

/*----------------------------------------------------------------------
 *
 * Trace Session.
 *
 */

/*++
	Structure Description:
		Defines an interface. May be implemented for either
		user mode- or kernel mode tracing.
--*/
typedef struct _JPFSV_TRACE_SESSION
{
	HRESULT ( *Start )(
		__in struct _JPFSV_TRACE_SESSION *This,
		__in UINT BufferCount,
		__in UINT BufferSize,
		__in PJPFSV_EVENT_PROESSOR EventProcessor
		);

	HRESULT ( *InstrumentProcedure )(
		__in struct _JPFSV_TRACE_SESSION *This,
		__in JPFSV_TRACE_ACTION Action,
		__in UINT ProcedureCount,
		__in_ecount(InstrCount) CONST PJPFBT_PROCEDURE Procedures,
		__out_opt PJPFBT_PROCEDURE FailedProcedure
		);

	HRESULT ( *CheckProcedureInstrumentability)(
		__in struct _JPFSV_TRACE_SESSION *This,
		__in DWORD_PTR ProcAddress,
		__out PBOOL Instrumentable,
		__out PUINT PaddingSize 
		);

	/*++
		Parameters:
			Wait		Specify whether to wait until all asynchronous
						operations have finished. 
	--*/
	HRESULT ( *Stop )(
		__in struct _JPFSV_TRACE_SESSION *This,
		__in BOOL Wait
		);

	VOID ( *Reference )(
		__in struct _JPFSV_TRACE_SESSION *This
		);

	/*++
		This method may fail with JPFSV_E_TRACES_ACTIVE.
	--*/
	HRESULT ( *Dereference )(
		__in struct _JPFSV_TRACE_SESSION *This
		);
} JPFSV_TRACE_SESSION, *PJPFSV_TRACE_SESSION;

/*++
	Routine Description:
		Create a session for user mode tracing. To be called by
		context.
--*/
HRESULT JpfsvpCreateProcessTraceSession(
	__in JPFSV_HANDLE ContextHandle,
	__out PJPFSV_TRACE_SESSION *Session
	);

/*++
	Routine Description:
		Create a session for kernel mode tracing. To be called by
		context.

	Parameters:
		LogFilePath	- only required for default tracing.
--*/
HRESULT JpfsvpCreateKernelTraceSession(
	__in JPFSV_HANDLE ContextHandle,
	__in JPFSV_TRACING_TYPE TracingType,
	__in_opt PCWSTR LogFilePath,
	__out PJPFSV_TRACE_SESSION *Session
	);

/*----------------------------------------------------------------------
 *
 * TracePoint Table.
 *
 * The TracePoint Table is NOT threadsafe!
 *
 */
typedef struct _JPFSV_TRACEPOINT_TABLE
{
	//
	// Hashtable: Proc VA -> Information.
	//
	JPHT_HASHTABLE Table;
} JPFSV_TRACEPOINT_TABLE, *PJPFSV_TRACEPOINT_TABLE;


/*++
	Routine Description:
		Initialize table.
--*/
HRESULT JpfsvpInitializeTracepointTable(
	__in PJPFSV_TRACEPOINT_TABLE Table
	);

/*++
	Routine Description:
		Remove all active tracepoints, but do not remove them 
		from table yet. This call shouls be closely follows by
		a call to JpfsvpFlushTracepointTable.
--*/
HRESULT JpfsvpRemoveAllTracepointsButKeepThemInTracepointTable(
	__in PJPFSV_TRACEPOINT_TABLE Table,
	__in PJPFSV_TRACE_SESSION TraceSession
	);

/*++
	Routine Description:
		Delete all entries from tracepoint table. Must be called
		after JpfsvpRemoveAllTracepointsButKeepThemInTracepointTable.
--*/
VOID JpfsvpFlushTracepointTable(
	__in PJPFSV_TRACEPOINT_TABLE Table
	);

/*++
	Routine Description:
		Initialize table. All tracepoints must have been 
		removed before calling this routine.
--*/
HRESULT JpfsvpDeleteTracepointTable(
	__in PJPFSV_TRACEPOINT_TABLE Table
	);

/*++
	Routine Description:
		Add an entry to the tracepoint table. 

	Return Value:
		S_OK if successfully inserted.
		JPFSV_E_TRACEPOINT_EXISTS is an entry already existed for 
			this procedure.
--*/
HRESULT JpfsvpAddEntryTracepointTable(
	__in PJPFSV_TRACEPOINT_TABLE Table,
	__in HANDLE Process,
	__in JPFBT_PROCEDURE Proc
	);

/*++
	Routine Description:
		Remove an entry from the tracepoint table. 

	Return Value:
		S_OK is successfully inserted.
		JPFSV_E_TRACEPOINT_NOT_FOUND if entry not found.
--*/
HRESULT JpfsvpRemoveEntryTracepointTable(
	__in PJPFSV_TRACEPOINT_TABLE Table,
	__in JPFBT_PROCEDURE Proc
	);

/*++
	Routine Description:
		Check if a tracepoint entry exists.
--*/
BOOL JpfsvpExistsEntryTracepointTable(
	__in PJPFSV_TRACEPOINT_TABLE Table,
	__in JPFBT_PROCEDURE Proc
	);

/*++
	Routine Description:
		Get number of tracepoints.
--*/
UINT JpfsvpGetEntryCountTracepointTable(
	__in PJPFSV_TRACEPOINT_TABLE Table
	);

/*++
	Routine Description:
		Enumerate table enries.
--*/
VOID JpfsvpEnumTracepointTable(
	__in PJPFSV_TRACEPOINT_TABLE Table,
	__in JPFSV_ENUM_TRACEPOINTS_ROUTINE Callback,
	__in_opt PVOID CallbackContext
	);

/*++
	Routine Description:
		Retrieve a copy of an entry in the table.

	Return Value: S_OK or JPFSV_E_TRACEPOINT_NOT_FOUND.
--*/
HRESULT JpfsvpGetEntryTracepointTable(
	__in PJPFSV_TRACEPOINT_TABLE Table,
	__in JPFBT_PROCEDURE Proc,
	__out PJPFSV_TRACEPOINT Tracepoint
	);

/*----------------------------------------------------------------------
 *
 * Definitions for commands.
 *
 */

typedef struct _JPFSV_COMMAND_PROCESSOR_STATE
{
	//
	// Context to be used by commands.
	//
	JPFSV_HANDLE Context;

	//
	// Cdiag session for event processing.
	//
	CDIAG_SESSION_HANDLE DiagSession;

	//
	// Resolver for error messages (also used by diag session).
	//
	PCDIAG_MESSAGE_RESOLVER MessageResolver;

	JPFSV_OUTPUT_ROUTINE OutputRoutine;
} JPFSV_COMMAND_PROCESSOR_STATE, *PJPFSV_COMMAND_PROCESSOR_STATE;

typedef BOOL ( * JPFSV_COMMAND_ROUTINE ) (
	__in PJPFSV_COMMAND_PROCESSOR_STATE ProcessorState,
	__in PCWSTR CommandName,
	__in UINT Argc,
	__in PCWSTR* Argv
	);

/*----------------------------------------------------------------------
 *
 * Commands.
 *
 */
VOID JpfsvpOutputError( 
	__in PJPFSV_COMMAND_PROCESSOR_STATE ProcessorState,
	__in HRESULT Hr
	);

VOID __cdecl JpfsvpOutput( 
	__in PJPFSV_COMMAND_PROCESSOR_STATE ProcessorState,
	__in PCWSTR Format,
	...
	);

BOOL JpfsvpEchoCommand(
	__in PJPFSV_COMMAND_PROCESSOR_STATE ProcessorState,
	__in PCWSTR CommandName,
	__in UINT Argc,
	__in PCWSTR* Argv
	);

BOOL JpfsvpListProcessesCommand(
	__in PJPFSV_COMMAND_PROCESSOR_STATE ProcessorState,
	__in PCWSTR CommandName,
	__in UINT Argc,
	__in PCWSTR* Argv
	);

BOOL JpfsvpListModulesCommand(
	__in PJPFSV_COMMAND_PROCESSOR_STATE ProcessorState,
	__in PCWSTR CommandName,
	__in UINT Argc,
	__in PCWSTR* Argv
	);

BOOL JpfsvpSearchSymbolCommand(
	__in PJPFSV_COMMAND_PROCESSOR_STATE ProcessorState,
	__in PCWSTR CommandName,
	__in UINT Argc,
	__in PCWSTR* Argv
	);

BOOL JpfsvpAttachCommand(
	__in PJPFSV_COMMAND_PROCESSOR_STATE ProcessorState,
	__in PCWSTR CommandName,
	__in UINT Argc,
	__in PCWSTR* Argv
	);

BOOL JpfsvpDetachCommand(
	__in PJPFSV_COMMAND_PROCESSOR_STATE ProcessorState,
	__in PCWSTR CommandName,
	__in UINT Argc,
	__in PCWSTR* Argv
	);

BOOL JpfsvpSetTracepointCommand(
	__in PJPFSV_COMMAND_PROCESSOR_STATE ProcessorState,
	__in PCWSTR CommandName,
	__in UINT Argc,
	__in PCWSTR* Argv
	);

BOOL JpfsvpClearTracepointCommand(
	__in PJPFSV_COMMAND_PROCESSOR_STATE ProcessorState,
	__in PCWSTR CommandName,
	__in UINT Argc,
	__in PCWSTR* Argv
	);

BOOL JpfsvpListTracepointsCommand(
	__in PJPFSV_COMMAND_PROCESSOR_STATE ProcessorState,
	__in PCWSTR CommandName,
	__in UINT Argc,
	__in PCWSTR* Argv
	);

BOOL JpfsvpSymolSearchPath(
	__in PJPFSV_COMMAND_PROCESSOR_STATE ProcessorState,
	__in PCWSTR CommandName,
	__in UINT Argc,
	__in PCWSTR* Argv
	);
/*-------------------------------------------------------------------------
 *
 * pg_variables.c
 *	  Functions, which get or set variables values
 *
 * Copyright (c) 2015-2022, Postgres Professional
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"
#include "fmgr.h"
#include "funcapi.h"
#include "miscadmin.h"

#include "access/htup_details.h"
#include "access/xact.h"
/*
 * PG 13 split tuptoaster.c into detoast.c/heaptoast.c (commit 8b94dab0) and, in
 * the same release, renamed heap_tuple_fetch_attr() to detoast_external_attr()
 * (commit 2e8b6bfa).  Both the header and the function name change at PG 13, so
 * a single guard provides the modern spelling on older versions.
 */
#if PG_VERSION_NUM >= 130000
#include "access/detoast.h"
#else
#include "access/tuptoaster.h"
#define detoast_external_attr(attr) heap_tuple_fetch_attr(attr)
#endif
#include "catalog/pg_type.h"
#include "parser/scansup.h"
#include "storage/proc.h"
#include "utils/builtins.h"
#include "utils/datum.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/timestamp.h"
#include "utils/typcache.h"

#include "pg_variables.h"

PG_MODULE_MAGIC;

/* Functions to work with records */
PG_FUNCTION_INFO_V1(variable_insert);
PG_FUNCTION_INFO_V1(variable_update);
PG_FUNCTION_INFO_V1(variable_delete);

PG_FUNCTION_INFO_V1(variable_select);
PG_FUNCTION_INFO_V1(variable_select_by_value);
PG_FUNCTION_INFO_V1(variable_select_by_values);

/* Functions to work with packages */
PG_FUNCTION_INFO_V1(variable_exists);
PG_FUNCTION_INFO_V1(package_exists);
PG_FUNCTION_INFO_V1(remove_variable);
PG_FUNCTION_INFO_V1(remove_package);
PG_FUNCTION_INFO_V1(remove_packages);
PG_FUNCTION_INFO_V1(get_packages_and_variables);
PG_FUNCTION_INFO_V1(get_packages_stats);

extern void _PG_init(void);
#if PG_VERSION_NUM < 150000
extern void _PG_fini(void);
#endif
static void ensurePackagesHashExists(void);
static void getKeyFromName(text *name, char *key);
static inline bool textNameEquals(text *name, const char *key);
static inline bool cachedPackageMatches(text *name, bool is_trans,
										bool require_htab);
static inline bool cachedVariableMatches(text *name, Package *package);
static inline Oid getCachedArgType(FunctionCallInfo fcinfo, int argnum);
static Package *getCachedPackage(text *name, bool strict);
static Variable *getCachedVariable(Package *package, text *name,
									Oid typid, bool is_record, bool strict);

static Package *getPackage(text *name, bool strict);
static Package *createPackage(text *name, bool is_trans);
static Variable *getVariableInternal(Package *package, text *name,
									 Oid typid, bool is_record, bool strict);
static Variable *createVariableInternal(Package *package, text *name, Oid typid,
										bool is_record, bool is_transactional);
static void removePackageInternal(Package *package);
static void resetVariablesCache(void);

/* Functions to work with transactional objects */
static void createSavepoint(TransObject *object, TransObjectType type);
static void ensureObjectSavedInCurrentTrans(TransObject *object,
											TransObjectType type);
static void ensureTombstoneSavedInCurrentTrans(Variable *variable,
											   int removal_level);
static void releaseSavepoint(TransObject *object, TransObjectType type, bool sub);
static void rollbackSavepoint(TransObject *object, TransObjectType type, bool sub);
static void discardTransactionalSavepoint(TransObject *object);

static void copyValue(VarState *src, VarState *dest, Variable *destVar);
static void freeValue(VarState *varstate, bool is_record);
static void removeState(TransObject *object, TransObjectType type,
						TransState *stateToDelete);
static bool isObjectChangedInCurrentTrans(TransObject *object);
static bool isObjectChangedInUpperTrans(TransObject *object);

static void addToChangesStack(TransObject *object, TransObjectType type);
static void addToChangesStackUpperLevel(TransObject *object,
										TransObjectType type);
static void pushChangesStack(int level);
static bool shouldDiscardTransactionalOnCommit(void);

static int	numOfRegVars(Package *package);

#ifdef PGPRO_EE
static void pgvSaveContext(void);
static void pgvRestoreContext(bool committed);
#endif

/* Constructors */
static void makePackHTAB(Package *package, bool is_trans);
static inline ChangedObject * makeChangedObject(TransObject *object,
												MemoryContext ctx);
static void initObjectHistory(TransObject *object, TransObjectType type);

#if PG_VERSION_NUM >= 120000
#define CHECK_ARGS_FOR_NULL() \
do { \
	if (fcinfo->args[0].isnull) \
		ereport(ERROR, \
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE), \
				 errmsg("package name can not be NULL"))); \
	if (fcinfo->args[1].isnull) \
		ereport(ERROR, \
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE), \
				 errmsg("variable name can not be NULL"))); \
} while(0)
#else							/* PG_VERSION_NUM < 120000 */
#define CHECK_ARGS_FOR_NULL() \
do { \
	if (fcinfo->argnull[0]) \
		ereport(ERROR, \
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE), \
				 errmsg("package name can not be NULL"))); \
	if (fcinfo->argnull[1]) \
		ereport(ERROR, \
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE), \
				 errmsg("variable name can not be NULL"))); \
} while(0)
#endif							/* PG_VERSION_NUM */

/* User controlled GUCs */
bool convert_unknownoid;

static HTAB *packagesHash = NULL;
static MemoryContext ModuleContext = NULL;

/* Recent package */
static Package *LastPackage = NULL;

/* Recent variable */
static Variable *LastVariable = NULL;

/* This stack contains lists of changed variables and packages per each subxact level */
static dlist_head *changesStack = NULL;
static MemoryContext changesStackContext = NULL;

/*
 * Intrusive doubly-linked lists of active variable and package scans.
 *
 * Keeping the list linkage inside each entry avoids TopTransactionContext
 * allocations and DEBUG_LIST_MEMORY_USAGE reallocations when scans close
 * during savepoint release, rollback, or transaction cleanup.
 */
static dlist_head variables_stats = DLIST_STATIC_INIT(variables_stats);
static dlist_head packages_stats = DLIST_STATIC_INIT(packages_stats);

typedef struct tagPackageStatSnapshot
{
	char		name[NAMEDATALEN];
	Size		used_memory;
}			PackageStatSnapshot;

typedef struct tagVariableStatEntry
{
	dlist_node	node;
	HTAB	   *hash;
	HASH_SEQ_STATUS *status;
	Variable   *variable;
	Package    *package;
	Levels		levels;
	void	  **user_fctx; /* pointer to funcctx->user_fctx */
	bool		active;
	bool		full_scan;
	bool		materialize;
	HashRecordEntry **rows;
	long		num_rows;
	long		next_row;
	MemoryContextCallback callback;
}			VariableStatEntry;

typedef struct tagPackageStatEntry
{
	dlist_node	node;
	HASH_SEQ_STATUS *status;
	Levels		levels;
	void	  **user_fctx; /* pointer to funcctx->user_fctx */
	bool		active;
	bool		materialize;
	PackageStatSnapshot *rows;
	long		num_rows;
	long		next_row;
	MemoryContextCallback callback;
}			PackageStatEntry;

#ifdef PGPRO_EE
/*
 * Context for storing/restoring parameters when switching autonomous
 * transactions
 */
typedef struct PgvContextStruct
{
	dlist_head *changesStack;
	MemoryContext changesStackContext;
	int			atxlevel;
	struct PgvContextStruct *next;
} PgvContextStruct;

static PgvContextStruct *pgv_context = NULL;
static int	active_atx_level = 0;

#endif							/* PGPRO_EE */

/*
 * Compare functions for VariableStatEntry and PackageStatEntry members.
 */
static bool
VariableStatEntry_status_eq(void *entry, void *value)
{
	return ((VariableStatEntry *) entry)->status == (HASH_SEQ_STATUS *) value;
}

static bool
VariableStatEntry_ptr_eq(void *entry, void *value)
{
	return entry == value;
}

static bool
VariableStatEntry_variable_eq(void *entry, void *value)
{
	return ((VariableStatEntry *) entry)->variable == (Variable *) value;
}

static bool
VariableStatEntry_hash_eq(void *entry, void *value)
{
	return ((VariableStatEntry *) entry)->hash == (HTAB *) value;
}

static bool
VariableStatEntry_package_eq(void *entry, void *value)
{
	return ((VariableStatEntry *) entry)->package == (Package *) value;
}

static bool
VariableStatEntry_eq_all(void *entry, void *value)
{
	return true;
}

static bool
VariableStatEntry_level_eq(void *entry, void *value)
{
	return
#ifdef PGPRO_EE
	/* Compare ATX level */
		((VariableStatEntry *) entry)->levels.atxlevel == ((Levels *) value)->atxlevel &&
#endif
		((VariableStatEntry *) entry)->levels.level == ((Levels *) value)->level;
}

static bool
PackageStatEntry_status_eq(void *entry, void *value)
{
	return ((PackageStatEntry *) entry)->status == (HASH_SEQ_STATUS *) value;
}

static bool
PackageStatEntry_ptr_eq(void *entry, void *value)
{
	return entry == value;
}

static bool
PackageStatEntry_eq_all(void *entry, void *value)
{
	return true;
}

static bool
PackageStatEntry_has_status(void *entry, void *value)
{
	return ((PackageStatEntry *) entry)->status != NULL;
}

static bool
PackageStatEntry_level_eq(void *entry, void *value)
{
	return
#ifdef PGPRO_EE
	/* Compare ATX level */
		((PackageStatEntry *) entry)->levels.atxlevel == ((Levels *) value)->atxlevel &&
#endif
		((PackageStatEntry *) entry)->levels.level == ((Levels *) value)->level;
}

#ifdef PGPRO_EE
static bool
VariableStatEntry_is_transactional(void *entry, void *value)
{
	return ((VariableStatEntry *) entry)->variable->is_transactional;
}

/*
 * Match entries started at the given ATX level or deeper.
 */
static bool
VariableStatEntry_atxlevel_ge(void *entry, void *value)
{
	return ((VariableStatEntry *) entry)->levels.atxlevel >= *(int *) value;
}

static bool
PackageStatEntry_atxlevel_ge(void *entry, void *value)
{
	return ((PackageStatEntry *) entry)->levels.atxlevel >= *(int *) value;
}
#endif

/*
 * VariableStatEntry and PackageStatEntry status member getters.
 */
static HASH_SEQ_STATUS *
VariableStatEntry_status_ptr(void *entry)
{
	return ((VariableStatEntry *) entry)->status;
}

static HASH_SEQ_STATUS *
PackageStatEntry_status_ptr(void *entry)
{
	return ((PackageStatEntry *) entry)->status;
}

/*
 * VariableStatEntry and PackageStatEntry functions for clear function context.
 */
static void
VariableStatEntry_clear_fctx(void *entry)
{
	VariableStatEntry *e = (VariableStatEntry *) entry;
	if (e->user_fctx)
		*e->user_fctx = NULL;
}

static void
PackageStatEntry_clear_fctx(void *entry)
{
	PackageStatEntry *e = (PackageStatEntry *) entry;
	if (e->user_fctx)
		*e->user_fctx = NULL;
}

static void
VariableStatEntry_deactivate(void *entry)
{
	((VariableStatEntry *) entry)->active = false;
}

static void
PackageStatEntry_deactivate(void *entry)
{
	((PackageStatEntry *) entry)->active = false;
}

/*
 * Generic remove_if algorithm.
 *
 * For every item in the list:
 *  1. Comapare item with value by eq function call.
 *  2. If eq return true, then step 3, else goto 7.
 *  3. Delete item from list.
 *  4. If term is true, call hash_seq_term.
 *  5. Free memory.
 *  6. If match_first if true return.
 *  7. Fetch next item.
 *
 */
typedef struct tagRemoveIfContext
{
	dlist_head *list;			/* target list */
	void	   *value;			/* value to compare with */
	bool		(*eq) (void *, void *); /* list item eq to value func */
	HASH_SEQ_STATUS *(*getter) (void *);	/* status getter */
	bool		match_first;	/* return on first match */
	bool		term;			/* hash_seq_term on match */
	void		(*clear_fctx) (void *); /* clear function context */
	void		(*deactivate) (void *); /* mark entry inactive */
}			RemoveIfContext;

static bool
list_remove_if(RemoveIfContext ctx)
{
	dlist_mutable_iter iter;
	bool		found = false;

	dlist_foreach_modify(iter, ctx.list)
	{
		void	   *entry = iter.cur;

		if (ctx.eq(entry, ctx.value))
		{
			dlist_delete(iter.cur);

			if (ctx.term && ctx.getter(entry))
#ifdef PGPRO_EE
				hash_seq_term_all_levels(ctx.getter(entry));
#else
				hash_seq_term(ctx.getter(entry));
#endif

			ctx.clear_fctx(entry);
			ctx.deactivate(entry);

			if (ctx.match_first)
				return true;

			found = true;
		}
	}

	return found;
}

/*
 * Remove first entry for status.
 */
static void
remove_variables_status(dlist_head *list, HASH_SEQ_STATUS *status)
{
	RemoveIfContext ctx =
	{
		.list = list,
		.value = status,
		.eq = VariableStatEntry_status_eq,
		.getter = VariableStatEntry_status_ptr,
		.match_first = true,
		.term = false,
		.clear_fctx = VariableStatEntry_clear_fctx,
		.deactivate = VariableStatEntry_deactivate
	};

	list_remove_if(ctx);
}

/*
 * Remove first entry for variable.
 */
static void
remove_variables_variable(dlist_head *list, Variable *variable)
{
	/*
	 * It may be more than one item in the list for each variable in case of
	 * cursor. So match_first is false here.
	 */
	RemoveIfContext ctx =
	{
		.list = list,
		.value = variable,
		.eq = VariableStatEntry_variable_eq,
		.getter = VariableStatEntry_status_ptr,
		.match_first = false,
		.term = true,
		.clear_fctx = VariableStatEntry_clear_fctx,
		.deactivate = VariableStatEntry_deactivate
	};

	list_remove_if(ctx);
}

/*
 * Remove all the entries for record hash.
 */
static void
remove_variables_hash(dlist_head *list, HTAB *hash)
{
	RemoveIfContext ctx =
	{
		.list = list,
		.value = hash,
		.eq = VariableStatEntry_hash_eq,
		.getter = VariableStatEntry_status_ptr,
		.match_first = false,
		.term = true,
		.clear_fctx = VariableStatEntry_clear_fctx,
		.deactivate = VariableStatEntry_deactivate
	};

	list_remove_if(ctx);
}

/*
 * Remove all the entries for package.
 */
static void
remove_variables_package(dlist_head *list, Package *package)
{
	RemoveIfContext ctx =
	{
		.list = list,
		.value = package,
		.eq = VariableStatEntry_package_eq,
		.getter = VariableStatEntry_status_ptr,
		.match_first = false,
		.term = true,
		.clear_fctx = VariableStatEntry_clear_fctx,
		.deactivate = VariableStatEntry_deactivate
	};

	list_remove_if(ctx);
}

/*
 * Remove all the entries for level.
 */
static void
remove_variables_level(dlist_head *list, Levels *levels)
{
	RemoveIfContext ctx =
	{
		.list = list,
		.value = levels,
		.eq = VariableStatEntry_level_eq,
		.getter = VariableStatEntry_status_ptr,
		.match_first = false,
		.term = false,
		.clear_fctx = VariableStatEntry_clear_fctx,
		.deactivate = VariableStatEntry_deactivate
	};

	list_remove_if(ctx);
}

/*
 * Delete variables stats list.
 */
static void
remove_variables_all(dlist_head *list)
{
	RemoveIfContext ctx =
	{
		.list = list,
		.value = NULL,
		.eq = VariableStatEntry_eq_all,
		.getter = VariableStatEntry_status_ptr,
		.match_first = false,
		.term = true,
		.clear_fctx = VariableStatEntry_clear_fctx,
		.deactivate = VariableStatEntry_deactivate
	};

	list_remove_if(ctx);
}

/*
 * Remove first entrie with status for packages list.
 */
static void
remove_packages_status(dlist_head *list, HASH_SEQ_STATUS *status)
{
	RemoveIfContext ctx =
	{
		.list = list,
		.value = status,
		.eq = PackageStatEntry_status_eq,
		.getter = PackageStatEntry_status_ptr,
		.match_first = true,
		.term = false,
		.clear_fctx = PackageStatEntry_clear_fctx,
		.deactivate = PackageStatEntry_deactivate
	};

	list_remove_if(ctx);
}

/*
 * Remove all the entries with level for packages list.
 */
static void
remove_packages_level(dlist_head *list, Levels *levels)
{
	RemoveIfContext ctx =
	{
		.list = list,
		.value = levels,
		.eq = PackageStatEntry_level_eq,
		.getter = PackageStatEntry_status_ptr,
		.match_first = false,
		.term = true,
		.clear_fctx = PackageStatEntry_clear_fctx,
		.deactivate = PackageStatEntry_deactivate
	};

	list_remove_if(ctx);
}

/*
 * Remove all the entries for packages stats list.
 */
static void
remove_packages_all(dlist_head *list)
{
	RemoveIfContext ctx =
	{
		.list = list,
		.value = NULL,
		.eq = PackageStatEntry_eq_all,
		.getter = PackageStatEntry_status_ptr,
		.match_first = false,
		.term = true,
		.clear_fctx = PackageStatEntry_clear_fctx,
		.deactivate = PackageStatEntry_deactivate
	};

	list_remove_if(ctx);
}

static void
remove_packages_unmaterialized(dlist_head *list)
{
	RemoveIfContext ctx =
	{
		.list = list,
		.value = NULL,
		.eq = PackageStatEntry_has_status,
		.getter = PackageStatEntry_status_ptr,
		.match_first = false,
		.term = true,
		.clear_fctx = PackageStatEntry_clear_fctx,
		.deactivate = PackageStatEntry_deactivate
	};

	list_remove_if(ctx);
}

#ifdef PGPRO_EE
/*
 * Remove all transactional entries.
 */
static void
remove_variables_transactional(dlist_head *list)
{
	RemoveIfContext ctx =
	{
		.list = list,
		.value = NULL,
		.eq = VariableStatEntry_is_transactional,
		.getter = VariableStatEntry_status_ptr,
		.match_first = false,
		.term = true,
		.clear_fctx = VariableStatEntry_clear_fctx,
		.deactivate = VariableStatEntry_deactivate
	};

	list_remove_if(ctx);
}

/*
 * Remove the variables entries started at ATX level atxlevel or deeper.
 */
static void
remove_variables_atxlevel(dlist_head *list, int atxlevel)
{
	RemoveIfContext ctx =
	{
		.list = list,
		.value = &atxlevel,
		.eq = VariableStatEntry_atxlevel_ge,
		.getter = VariableStatEntry_status_ptr,
		.match_first = false,
		.term = true,
		.clear_fctx = VariableStatEntry_clear_fctx,
		.deactivate = VariableStatEntry_deactivate
	};

	list_remove_if(ctx);
}

/*
 * Remove the packages entries started at ATX level atxlevel or deeper.
 */
static void
remove_packages_atxlevel(dlist_head *list, int atxlevel)
{
	RemoveIfContext ctx =
	{
		.list = list,
		.value = &atxlevel,
		.eq = PackageStatEntry_atxlevel_ge,
		.getter = PackageStatEntry_status_ptr,
		.match_first = false,
		.term = true,
		.clear_fctx = PackageStatEntry_clear_fctx,
		.deactivate = PackageStatEntry_deactivate
	};

	list_remove_if(ctx);
}
#endif

static void freeStatsLists(void);
static void variableStatEntryShutdown(void *arg);
static void packageStatEntryShutdown(void *arg);

/* Returns a lists of packages and variables changed at current subxact level */
#define get_actual_changes_list() \
	( \
		AssertMacro(changesStack != NULL), \
		(dlist_head_element(ChangesStackNode, node, changesStack)) \
	)
#define pack_hctx(pack, is_trans) \
			(is_trans ? pack->hctxTransact : pack->hctxRegular)
#define pack_htab(pack, is_trans) \
			(is_trans ? pack->varHashTransact : pack->varHashRegular)

#define PGV_MCXT_MAIN		"pg_variables: main memory context"
#define PGV_MCXT_VARS		"pg_variables: variables hash"
#define PGV_MCXT_STACK		"pg_variables: changesStack"


static inline bool
textNameEquals(text *name, const char *key)
{
	int			name_len = VARSIZE_ANY_EXHDR(name);

	/* initObjectHistory() initializes the key's entire fixed-size buffer. */
	return name_len < NAMEDATALEN &&
		key[name_len] == '\0' &&
		memcmp(VARDATA_ANY(name), key, name_len) == 0;
}

static inline bool
cachedPackageMatches(text *name, bool is_trans, bool require_htab)
{
	return LastPackage != NULL &&
		textNameEquals(name, GetName(LastPackage)) &&
		GetActualState(LastPackage)->is_valid &&
		(!require_htab || (!GetPackState(LastPackage)->is_removed &&
						  pack_htab(LastPackage, is_trans) != NULL));
}

static inline bool
isVariableValid(Variable *variable)
{
	/* ATX can leave regular values in a parent-removed package. */
	return GetActualState(variable)->is_valid &&
		(!variable->is_transactional ||
		 !GetPackState(variable->package)->is_removed);
}

static inline bool
cachedVariableMatches(text *name, Package *package)
{
	return LastVariable != NULL &&
		LastVariable->package == package &&
		textNameEquals(name, GetName(LastVariable)) &&
		isVariableValid(LastVariable);
}

static inline Oid
getCachedArgType(FunctionCallInfo fcinfo, int argnum)
{
	Oid		   *typid = (Oid *) fcinfo->flinfo->fn_extra;

	if (typid == NULL)
	{
		typid = (Oid *) MemoryContextAlloc(fcinfo->flinfo->fn_mcxt,
										   sizeof(Oid));
		*typid = get_fn_expr_argtype(fcinfo->flinfo, argnum);
		fcinfo->flinfo->fn_extra = typid;
	}

	return *typid;
}

static Package *
getCachedPackage(text *name, bool strict)
{
	Package    *package;

	if (likely(cachedPackageMatches(name, false, false)))
		return LastPackage;

	package = getPackage(name, strict);
	if (package != NULL)
	{
		LastPackage = package;
		LastVariable = NULL;
	}

	return package;
}

static Variable *
getCachedVariable(Package *package, text *name, Oid typid, bool is_record,
				  bool strict)
{
	Variable   *variable;

	if (likely(cachedVariableMatches(name, package)))
	{
		variable = LastVariable;

		if (typid == InvalidOid ||
			(variable->typid == typid && variable->is_record == is_record))
		{
			LastPackage = package;
			LastVariable = variable;
			return variable;
		}
	}

	variable = getVariableInternal(package, name, typid, is_record, strict);
	if (variable != NULL && GetActualState(variable)->is_valid)
		LastVariable = variable;

	return variable;
}

#ifndef ALLOCSET_DEFAULT_SIZES
#define ALLOCSET_DEFAULT_SIZES \
	ALLOCSET_DEFAULT_MINSIZE, ALLOCSET_DEFAULT_INITSIZE, ALLOCSET_DEFAULT_MAXSIZE
#endif

#ifndef ALLOCSET_START_SMALL_SIZES
#define ALLOCSET_START_SMALL_SIZES \
	ALLOCSET_SMALL_MINSIZE, ALLOCSET_SMALL_INITSIZE, ALLOCSET_DEFAULT_MAXSIZE
#endif


/*
 * Set value of variable, typlen could be 0 if typbyval == true
 */
static void
variable_set(text *package_name, text *var_name,
			 Oid typid, Datum value, bool is_null, bool is_transactional)
{
	Package    *package;
	Variable   *variable;
	ScalarVar  *scalar;

	if (likely(cachedPackageMatches(package_name, is_transactional, true)))
		package = LastPackage;
	else
	{
		package = createPackage(package_name, is_transactional);
		LastPackage = package;
		LastVariable = NULL;
	}

	if (likely(cachedVariableMatches(var_name, package) &&
			   LastVariable->typid == typid &&
			   !LastVariable->is_record &&
			   LastVariable->is_transactional == is_transactional))
	{
		variable = LastVariable;

		if (variable->is_transactional)
			ensureObjectSavedInCurrentTrans(&variable->transObject,
											TRANS_VARIABLE);
	}
	else
	{
		variable = createVariableInternal(package, var_name, typid, false,
										  is_transactional);
		LastVariable = variable;
	}

	scalar = &(GetActualValue(variable).scalar);

	{
		bool		old_is_byref = (!scalar->typbyval && !scalar->is_null);
		Datum		old_value = scalar->value;

		if (is_null)
		{
			if (old_is_byref)
				pfree(DatumGetPointer(old_value));
			scalar->value = 0;
			scalar->is_null = true;
		}
		else if (scalar->typbyval)
		{
			scalar->value = value;
			scalar->is_null = false;
		}
		else
		{
			MemoryContext oldcxt;
			MemoryContext valuecontext;

			/*
			 * A varlena value may arrive as an external TOAST reference
			 * (on-disk, indirect or expanded) whose target can be freed or
			 * vacuumed away before the stored value is read back.  Inline any
			 * such reference now, while preserving in-line compression, so the
			 * copy kept in the package context is self-contained.
			 */
			if (scalar->typlen == -1 &&
				VARATT_IS_EXTERNAL(DatumGetPointer(value)))
				value = PointerGetDatum(detoast_external_attr(
										(struct varlena *) DatumGetPointer(value)));

			/*
			 * Fixed-length pass-by-reference values always fit their existing
			 * buffer.  Equal-sized inline varlenas can reuse theirs too, provided
			 * neither value is external or compressed.  Short (1-byte header)
			 * varlenas are plain inline data and are allowed.
			 */
			if (old_is_byref && scalar->typlen > 0)
			{
				void	   *dst = DatumGetPointer(old_value);
				void	   *src = DatumGetPointer(value);

				/* Fixed-length values always fit the existing owned buffer. */
				if (dst != src)
					memcpy(dst, src, (Size) scalar->typlen);
				scalar->value = old_value;
			}
			else if (old_is_byref && scalar->typlen == -1 &&
				!VARATT_IS_EXTERNAL(DatumGetPointer(old_value)) &&
				!VARATT_IS_COMPRESSED(DatumGetPointer(old_value)) &&
				!VARATT_IS_EXTERNAL(DatumGetPointer(value)) &&
				!VARATT_IS_COMPRESSED(DatumGetPointer(value)) &&
				VARSIZE_ANY(DatumGetPointer(old_value)) ==
				VARSIZE_ANY(DatumGetPointer(value)))
			{
				memcpy(DatumGetPointer(old_value), DatumGetPointer(value),
					   VARSIZE_ANY(DatumGetPointer(value)));
				scalar->value = old_value;
			}
			else
			{
				Datum		new_value;

				/*
				 * Compute the copy before mutating the variable: datumCopy() can
				 * raise on OOM, so producing the new value first -- and freeing
				 * the old one only once it succeeds -- leaves scalar->value and
				 * scalar->is_null describing the still-valid old value on
				 * failure, instead of a freed buffer or a false is_null.
				 */
				valuecontext = pack_hctx(package, is_transactional);
				oldcxt = MemoryContextSwitchTo(valuecontext);
				new_value = datumCopy(value, false, scalar->typlen);
				MemoryContextSwitchTo(oldcxt);

				if (old_is_byref)
					pfree(DatumGetPointer(old_value));
				scalar->value = new_value;
			}

			scalar->is_null = false;
		}
	}
}

static Datum
variable_get(text *package_name, text *var_name,
			 Oid typid, bool *is_null, bool strict)
{
	Package    *package;
	Variable   *variable;
	ScalarVar  *scalar;

	package = getCachedPackage(package_name, strict);
	if (package == NULL)
	{
		*is_null = true;
		return 0;
	}

	variable = getCachedVariable(package, var_name, typid, false, strict);

	/*
	 * getVariableInternal() treats a removed variable as absent at strict=false
	 * and returns NULL, so return SQL NULL here as well.
	 */
	if (variable == NULL || !isVariableValid(variable))
	{
		*is_null = true;
		return 0;
	}

	scalar = &(GetActualValue(variable).scalar);
	*is_null = scalar->is_null;

	if (!scalar->is_null && !scalar->typbyval)
		return datumCopy(scalar->value, scalar->typbyval, scalar->typlen);

	return scalar->value;
}


#define VARIABLE_GET_TEMPLATE(pkg_arg, var_arg, strict_arg, type, typid) \
	PG_FUNCTION_INFO_V1(variable_get_##type); \
	Datum \
	variable_get_##type(PG_FUNCTION_ARGS) \
	{ \
		text	   *package_name; \
		text	   *var_name; \
		bool		strict; \
		bool		isnull; \
		Datum		value; \
		\
		CHECK_ARGS_FOR_NULL(); \
		\
		package_name = PG_GETARG_TEXT_PP(pkg_arg); \
		var_name = PG_GETARG_TEXT_PP(var_arg); \
		/* None of the getters are STRICT; treat a missing/NULL flag as the \
		 * SQL default (strict = true). */ \
		strict = (PG_NARGS() > (strict_arg) && !PG_ARGISNULL(strict_arg)) ? \
			PG_GETARG_BOOL(strict_arg) : true; \
		\
		value = variable_get(package_name, var_name, \
							 (typid), &isnull, strict); \
		\
		PG_FREE_IF_COPY(package_name, pkg_arg); \
		PG_FREE_IF_COPY(var_name, var_arg); \
		\
		if (!isnull) \
			PG_RETURN_DATUM(value); \
		else \
			PG_RETURN_NULL(); \
	}

/* deprecated functions */
VARIABLE_GET_TEMPLATE(0, 1, 2, int, INT4OID)
VARIABLE_GET_TEMPLATE(0, 1, 2, text, TEXTOID)
VARIABLE_GET_TEMPLATE(0, 1, 2, numeric, NUMERICOID)
VARIABLE_GET_TEMPLATE(0, 1, 2, timestamp, TIMESTAMPOID)
VARIABLE_GET_TEMPLATE(0, 1, 2, timestamptz, TIMESTAMPTZOID)
VARIABLE_GET_TEMPLATE(0, 1, 2, date, DATEOID)
VARIABLE_GET_TEMPLATE(0, 1, 2, jsonb, JSONBOID)

/* current API */
VARIABLE_GET_TEMPLATE(0, 1, 3, any, getCachedArgType(fcinfo, 2))
VARIABLE_GET_TEMPLATE(0, 1, 3, array, getCachedArgType(fcinfo, 2))


#define VARIABLE_SET_TEMPLATE(type, typid) \
	PG_FUNCTION_INFO_V1(variable_set_##type); \
	Datum \
	variable_set_##type(PG_FUNCTION_ARGS) \
	{ \
		text	   *package_name; \
		text	   *var_name; \
		bool		is_transactional; \
		\
		CHECK_ARGS_FOR_NULL(); \
		\
		package_name = PG_GETARG_TEXT_PP(0); \
		var_name = PG_GETARG_TEXT_PP(1); \
		/* \
		 * The 1.0 catalog still ships 3-argument setters bound to this same \
		 * C symbol, so args[3] may be out of bounds. Read the flag only when \
		 * it is actually present (guards a post-pg_upgrade window where a bad \
		 * read would silently make the value transactional and lose it). \
		 */ \
		is_transactional = (PG_NARGS() > 3 && !PG_ARGISNULL(3)) ? \
			PG_GETARG_BOOL(3) : false; \
		\
		variable_set(package_name, var_name, (typid), \
					 PG_ARGISNULL(2) ? 0 : PG_GETARG_DATUM(2), \
					 PG_ARGISNULL(2), is_transactional); \
		\
		PG_FREE_IF_COPY(package_name, 0); \
		PG_FREE_IF_COPY(var_name, 1); \
		PG_RETURN_VOID(); \
	}


/* deprecated functions */
VARIABLE_SET_TEMPLATE(int, INT4OID)
VARIABLE_SET_TEMPLATE(text, TEXTOID)
VARIABLE_SET_TEMPLATE(numeric, NUMERICOID)
VARIABLE_SET_TEMPLATE(timestamp, TIMESTAMPOID)
VARIABLE_SET_TEMPLATE(timestamptz, TIMESTAMPTZOID)
VARIABLE_SET_TEMPLATE(date, DATEOID)
VARIABLE_SET_TEMPLATE(jsonb, JSONBOID)

/* current API */
VARIABLE_SET_TEMPLATE(any, getCachedArgType(fcinfo, 2))
VARIABLE_SET_TEMPLATE(array, getCachedArgType(fcinfo, 2))


Datum
variable_insert(PG_FUNCTION_ARGS)
{
	text	   *package_name;
	text	   *var_name;
	HeapTupleHeader rec;
	Package    *package;
	Variable   *variable;
	bool		is_transactional;

	Oid			tupType;
	int32		tupTypmod;
	TupleDesc	tupdesc = NULL;
	RecordVar  *record;

	/* Checks */
	CHECK_ARGS_FOR_NULL();

	if (PG_ARGISNULL(2))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("record argument can not be NULL")));

	/* Get arguments */
	package_name = PG_GETARG_TEXT_PP(0);
	var_name = PG_GETARG_TEXT_PP(1);
	check_record_callback_text(package_name, var_name);
	rec = PG_GETARG_HEAPTUPLEHEADER(2);
	/* See VARIABLE_SET_TEMPLATE: the 1.0 pgv_insert() has no 4th argument. */
	is_transactional = (PG_NARGS() > 3 && !PG_ARGISNULL(3)) ?
		PG_GETARG_BOOL(3) : false;

	/* Get cached package */
	if (likely(cachedPackageMatches(package_name, is_transactional, true)))
		package = LastPackage;
	else
	{
		package = createPackage(package_name, is_transactional);
		LastPackage = package;
		LastVariable = NULL;
	}

	/* Get cached variable */
	if (likely(cachedVariableMatches(var_name, package) &&
			   LastVariable->typid == RECORDOID &&
			   LastVariable->is_record &&
			   LastVariable->is_transactional == is_transactional))
	{
		TransObject *transObj;

		variable = LastVariable;
		check_record_callback_mutation(NULL, variable);
		transObj = &variable->transObject;

		if (variable->is_transactional)
			ensureObjectSavedInCurrentTrans(transObj, TRANS_VARIABLE);
	}
	else
	{
		variable = createVariableInternal(package, var_name, RECORDOID,
										  true, is_transactional);
		LastVariable = variable;
	}

	/* Insert a record */
	tupType = HeapTupleHeaderGetTypeId(rec);
	tupTypmod = HeapTupleHeaderGetTypMod(rec);

	record = &(GetActualValue(variable).record);

	/*
	 * Fast path: a non-first record whose rowtype exactly matches the last one
	 * validated for this variable state needs neither a tuple-descriptor lookup
	 * nor an attribute re-check. Only anonymous RECORD types are cached, and
	 * their typmod is immutable within the backend, so the stored structure is
	 * guaranteed identical and no UNKNOWN coercion is required. insert_record()
	 * uses record->tupdesc, so the input descriptor is not needed here.
	 */
	if (record->tupdesc && !variable->is_deleted &&
		tupType == RECORDOID &&
		tupType == record->last_checked_typeid &&
		tupTypmod == record->last_checked_typmod)
	{
		insert_record(variable, rec, NULL);

		PG_FREE_IF_COPY(package_name, 0);
		PG_FREE_IF_COPY(var_name, 1);

		PG_RETURN_VOID();
	}

	if (!record->tupdesc || variable->is_deleted)
	{
		MemoryContext oldcxt = CurrentMemoryContext;

		PG_TRY();
		{
			tupdesc = lookup_rowtype_tupdesc(tupType, tupTypmod);
			if (variable->is_deleted && record->hctx)
			{
				remove_variables_variable(&variables_stats, variable);
				MemoryContextDelete(record->hctx);
				memset(record, 0, sizeof(RecordVar));
			}

			if (convert_unknownoid)
				coerce_unknown_first_record(&tupdesc, &rec);

			init_record(record, tupdesc, variable);
			variable->is_deleted = false;
			insert_record(variable, rec, tupdesc);
		}
		PG_CATCH();
		{
			/* Regular entries survive abort, so discard incomplete records. */
			MemoryContextSwitchTo(oldcxt);
			removeVariable(variable);
			PG_RE_THROW();
		}
		PG_END_TRY();
	}
	else
	{
		/*
		 * We need to check attributes of the new row if this is a transient
		 * record type or if last record has different id.
		 * Also we convert UNKNOWNOID to TEXTOID if needed.
		 * tupdesc may be changed
		 */
		bool		coerced;

		tupdesc = lookup_rowtype_tupdesc(tupType, tupTypmod);
		coerced = check_attributes(variable, &rec, tupdesc);

		/*
		 * Cache this rowtype for the fast path only when it is an anonymous
		 * RECORD (named composites can change structure under a stable OID via
		 * ALTER TYPE) and needed no UNKNOWN coercion (the fast path does not run
		 * reconstruct_tuple()). Otherwise drop any stale cached type.
		 */
		if (!coerced && tupType == RECORDOID)
		{
			record->last_checked_typeid = tupType;
			record->last_checked_typmod = tupTypmod;
		}
		else
			record->last_checked_typeid = InvalidOid;

		insert_record(variable, rec, coerced ? NULL : tupdesc);
	}

	/* Release resources */
	if (tupdesc)
		ReleaseTupleDesc(tupdesc);

	PG_FREE_IF_COPY(package_name, 0);
	PG_FREE_IF_COPY(var_name, 1);

	PG_RETURN_VOID();
}

Datum
variable_update(PG_FUNCTION_ARGS)
{
	text	   *package_name;
	text	   *var_name;
	HeapTupleHeader rec;
	Package    *package;
	Variable   *variable;
	TransObject *transObject;
	bool		res;
	Oid			tupType;
	int32		tupTypmod;
	TupleDesc	tupdesc = NULL;

	/* Checks */
	CHECK_ARGS_FOR_NULL();

	if (PG_ARGISNULL(2))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("record argument can not be NULL")));

	/* Get arguments */
	package_name = PG_GETARG_TEXT_PP(0);
	var_name = PG_GETARG_TEXT_PP(1);
	rec = PG_GETARG_HEAPTUPLEHEADER(2);
	check_record_callback_text(package_name, var_name);

	/* Get cached package */
	package = getCachedPackage(package_name, true);

	/* Get cached variable */
	variable = getCachedVariable(package, var_name, RECORDOID, true, true);
	check_record_callback_mutation(NULL, variable);

	transObject = &variable->transObject;
	if (variable->is_transactional)
		ensureObjectSavedInCurrentTrans(transObject, TRANS_VARIABLE);

	/* Update a record */
	tupType = HeapTupleHeaderGetTypeId(rec);
	tupTypmod = HeapTupleHeaderGetTypMod(rec);

	tupdesc = lookup_rowtype_tupdesc(tupType, tupTypmod);
	/*
	 * Convert UNKNOWNOID to TEXTOID if needed
	 * tupdesc may be changed
	 */
	res = update_record(variable, rec,
						check_attributes(variable, &rec, tupdesc) ? NULL : tupdesc);
	ReleaseTupleDesc(tupdesc);

	/* Release resources */
	PG_FREE_IF_COPY(package_name, 0);
	PG_FREE_IF_COPY(var_name, 1);

	PG_RETURN_BOOL(res);
}

Datum
variable_delete(PG_FUNCTION_ARGS)
{
	text	   *package_name;
	text	   *var_name;
	Oid			value_type;
	Datum		value;
	bool		value_is_null = PG_ARGISNULL(2);
	Package    *package;
	Variable   *variable;
	TransObject *transObject;
	bool		res;

	CHECK_ARGS_FOR_NULL();

	/* Get arguments */
	package_name = PG_GETARG_TEXT_PP(0);
	var_name = PG_GETARG_TEXT_PP(1);
	check_record_callback_text(package_name, var_name);

	if (!value_is_null)
	{
		value_type = getCachedArgType(fcinfo, 2);
		value = PG_GETARG_DATUM(2);
	}
	else
	{
		value_type = InvalidOid;
		value = 0;
	}

	/* Get cached package */
	package = getCachedPackage(package_name, true);

	/* Get cached variable */
	variable = getCachedVariable(package, var_name, RECORDOID, true, true);
	check_record_callback_mutation(NULL, variable);

	transObject = &variable->transObject;
	if (variable->is_transactional)
		ensureObjectSavedInCurrentTrans(transObject, TRANS_VARIABLE);

	/* Delete a record */
	if (!value_is_null)
		check_record_key(variable, value_type);
	res = delete_record(variable, value, value_is_null);

	/* Release resources */
	PG_FREE_IF_COPY(package_name, 0);
	PG_FREE_IF_COPY(var_name, 1);

	PG_RETURN_BOOL(res);
}

void
check_record_delete_allowed(Variable *variable)
{
	dlist_iter	iter;
	HTAB	   *hash = GetActualValue(variable).record.rhash;

	dlist_foreach(iter, &variables_stats)
	{
		VariableStatEntry *entry = dlist_container(VariableStatEntry, node,
												   iter.cur);

		if (entry->active && entry->full_scan && entry->hash == hash)
			ereport(ERROR,
					(errcode(ERRCODE_OBJECT_IN_USE),
					 errmsg("cannot delete records from variable \"%s\" while a full scan is active",
							GetName(variable)),
					 errhint("Close or finish the full scan before deleting records.")));
	}
}

/*
 * Reserve dynahash sequential-scan slots for server portal/catalog cleanup and
 * internal extension traversals so subtransaction abort cannot exhaust
 * MAX_SEQ_SCANS while scanning PortalHashTable.
 */
#define PGV_MAX_OPEN_SEQ_SCANS 64

static void
check_open_seq_scans_limit(void)
{
	dlist_iter	iter;
	int			active_scans = 0;

	dlist_foreach(iter, &variables_stats)
	{
		VariableStatEntry *entry = dlist_container(VariableStatEntry, node,
												   iter.cur);

		if (entry->active && entry->status != NULL)
			active_scans++;
	}
	dlist_foreach(iter, &packages_stats)
	{
		PackageStatEntry *entry = dlist_container(PackageStatEntry, node,
												  iter.cur);

		if (entry->active && entry->status != NULL)
			active_scans++;
	}

	if (active_scans >= PGV_MAX_OPEN_SEQ_SCANS)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("too many active pg_variables scans"),
				 errhint("Close or finish open pgv_select() or pgv_stats() cursors before opening more.")));
}

Datum
variable_select(PG_FUNCTION_ARGS)
{
	FuncCallContext *funcctx;
	HASH_SEQ_STATUS *rstat;
	HashRecordEntry *item;
	VariableStatEntry *entry;

	if (SRF_IS_FIRSTCALL())
	{
		MemoryContext oldcontext;
		text	   *package_name;
		text	   *var_name;
		Package    *package;
		Variable   *variable;
		RecordVar  *record;

		CHECK_ARGS_FOR_NULL();

		/* Get arguments */
		package_name = PG_GETARG_TEXT_PP(0);
		var_name = PG_GETARG_TEXT_PP(1);

		package = getCachedPackage(package_name, true);
		variable = getCachedVariable(package, var_name, RECORDOID, true,
									 true);
		check_open_seq_scans_limit();
		record = &(GetActualValue(variable).record);
		funcctx = SRF_FIRSTCALL_INIT();

		funcctx->tuple_desc = record->tupdesc;

		oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);

		rstat = (HASH_SEQ_STATUS *) palloc0(sizeof(HASH_SEQ_STATUS));
		entry = palloc0(sizeof(VariableStatEntry));
		entry->hash = record->rhash;
		entry->status = NULL;
		entry->variable = variable;
		entry->package = package;
		entry->levels.level = GetCurrentTransactionNestLevel();
#ifdef PGPRO_EE
		entry->levels.atxlevel = getNestLevelATX();
#endif
		entry->user_fctx = &funcctx->user_fctx;
		entry->active = true;
		entry->full_scan = true;
		entry->callback.func = variableStatEntryShutdown;
		entry->callback.arg = entry;

		dlist_push_head(&variables_stats, &entry->node);

		MemoryContextRegisterResetCallback(funcctx->multi_call_memory_ctx,
										   &entry->callback);
		hash_seq_init(rstat, record->rhash);
		entry->status = rstat;
		funcctx->user_fctx = entry;

		MemoryContextSwitchTo(oldcontext);
		PG_FREE_IF_COPY(package_name, 0);
		PG_FREE_IF_COPY(var_name, 1);
	}

	funcctx = SRF_PERCALL_SETUP();

	if (funcctx->user_fctx == NULL)
	{
		/*
		 * VariableStatEntry was removed. For example, after call
		 * 'ROLLBACK TO SAVEPOINT ...'
		 */
		SRF_RETURN_DONE(funcctx);
	}

	/* Get next hash record */
	entry = (VariableStatEntry *) funcctx->user_fctx;
	rstat = entry->status;
	if (rstat)
		item = (HashRecordEntry *) hash_seq_search(rstat);
	else
	{
		if (entry->next_row == entry->num_rows)
			SRF_RETURN_DONE(funcctx);
		item = entry->rows[entry->next_row++];
	}
	if (item != NULL)
	{
		Assert(!HeapTupleHeaderHasExternal(
										   (HeapTupleHeader) DatumGetPointer(item->tuple)));

		/* The caller may mutate the collection before consuming this row. */
		SRF_RETURN_NEXT(funcctx, datumCopy(item->tuple, false, -1));
	}
	else
	{
		if (rstat)
			remove_variables_status(&variables_stats, rstat);
		SRF_RETURN_DONE(funcctx);
	}
}

Datum
variable_select_by_value(PG_FUNCTION_ARGS)
{
	text	   *package_name;
	text	   *var_name;
	Oid			value_type;
	Datum		value;
	bool		value_is_null = PG_ARGISNULL(2);
	Package    *package;
	Variable   *variable;

	HashRecordEntry *item;
	RecordVar  *record;
	HashRecordKey k;
	bool		found;

	CHECK_ARGS_FOR_NULL();

	/* Get arguments */
	package_name = PG_GETARG_TEXT_PP(0);
	var_name = PG_GETARG_TEXT_PP(1);

	if (!value_is_null)
	{
		value_type = getCachedArgType(fcinfo, 2);
		value = PG_GETARG_DATUM(2);
	}
	else
	{
		value_type = InvalidOid;
		value = 0;
	}

	package = getCachedPackage(package_name, true);
	variable = getCachedVariable(package, var_name, RECORDOID, true, true);

	if (!value_is_null)
		check_record_key(variable, value_type);

	record = &(GetActualValue(variable).record);

	/* Search a record */
	k.value = value;
	k.is_null = value_is_null;
	k.record = record;

	item = (HashRecordEntry *) hash_search(record->rhash, &k,
										   HASH_FIND, &found);

	PG_FREE_IF_COPY(package_name, 0);
	PG_FREE_IF_COPY(var_name, 1);

	if (found)
	{
		Assert(!HeapTupleHeaderHasExternal(
										   (HeapTupleHeader) DatumGetPointer(item->tuple)));

		/*
		 * item->tuple lives in the variable's own memory context and can be
		 * freed (e.g. by an update or delete of the same record in the same
		 * query) before the returned Datum is materialised, so hand back a
		 * copy. This mirrors the datumCopy() that variable_get() does for
		 * by-reference scalars.
		 */
		PG_RETURN_DATUM(datumCopy(item->tuple, false, -1));
	}
	else
		PG_RETURN_NULL();
}

/* Structure for variable_select_by_values() */
typedef struct
{
	RecordVar  *record;
	ArrayIterator iterator;
}			VariableIteratorRec;

Datum
variable_select_by_values(PG_FUNCTION_ARGS)
{
	FuncCallContext *funcctx;
	VariableIteratorRec *var;
	Datum		value;
	HashRecordEntry *item;
	bool		isnull;

	if (SRF_IS_FIRSTCALL())
	{
		text	   *package_name;
		text	   *var_name;
		ArrayType  *values;
		Package    *package;
		Variable   *variable;
		RecordVar  *record;
		VariableStatEntry *entry;
		MemoryContext oldcontext;

		/* Checks */
		CHECK_ARGS_FOR_NULL();

		if (PG_ARGISNULL(2))
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("array argument can not be NULL")));

		/* Keep one flat copy alive for validation and all SRF calls. */
		funcctx = SRF_FIRSTCALL_INIT();
		oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);
		values = PG_GETARG_ARRAYTYPE_P_COPY(2);
		MemoryContextSwitchTo(oldcontext);

		if (ARR_NDIM(values) > 1)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("searching for elements in multidimensional arrays is not supported")));

		/* Get arguments */
		package_name = PG_GETARG_TEXT_PP(0);
		var_name = PG_GETARG_TEXT_PP(1);

		package = getCachedPackage(package_name, true);
		variable = getCachedVariable(package, var_name, RECORDOID, true,
									 true);
		record = &(GetActualValue(variable).record);

		check_record_key(variable, ARR_ELEMTYPE(values));

		oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);

		funcctx->tuple_desc = record->tupdesc;

		var = (VariableIteratorRec *) palloc(sizeof(VariableIteratorRec));
		var->iterator = array_create_iterator(values, 0, NULL);
		var->record = record;
		funcctx->user_fctx = var;

		entry = palloc0(sizeof(VariableStatEntry));
		entry->hash = record->rhash;
		entry->status = NULL;
		entry->variable = variable;
		entry->package = package;
		entry->levels.level = GetCurrentTransactionNestLevel();
#ifdef PGPRO_EE
		entry->levels.atxlevel = getNestLevelATX();
#endif
		entry->user_fctx = &funcctx->user_fctx;
		entry->active = true;
		entry->callback.func = variableStatEntryShutdown;
		entry->callback.arg = entry;

		dlist_push_head(&variables_stats, &entry->node);

		MemoryContextRegisterResetCallback(funcctx->multi_call_memory_ctx,
										   &entry->callback);

		MemoryContextSwitchTo(oldcontext);
		PG_FREE_IF_COPY(package_name, 0);
		PG_FREE_IF_COPY(var_name, 1);
	}

	funcctx = SRF_PERCALL_SETUP();
	if (funcctx->user_fctx == NULL)
		SRF_RETURN_DONE(funcctx);

	var = (VariableIteratorRec *) funcctx->user_fctx;

	/* Get next array element */
	while (array_iterate(var->iterator, &value, &isnull))
	{
		HashRecordKey k;
		bool		found;
		RecordVar  *record;

		CHECK_FOR_INTERRUPTS();
		record = var->record;
		/* Search a record */
		k.value = value;
		k.is_null = isnull;
		k.record = record;

		item = (HashRecordEntry *) hash_search(record->rhash, &k,
											   HASH_FIND, &found);
		if (funcctx->user_fctx == NULL)
			SRF_RETURN_DONE(funcctx);
		if (found)
		{
			Assert(!HeapTupleHeaderHasExternal(
											   (HeapTupleHeader) DatumGetPointer(item->tuple)));
			/* Keep the result alive if a sibling expression changes the row. */
			SRF_RETURN_NEXT(funcctx, datumCopy(item->tuple, false, -1));
		}
	}

	array_free_iterator(var->iterator);
	pfree(var);
	SRF_RETURN_DONE(funcctx);
}

/*
 * Check if variable exists.
 */
Datum
variable_exists(PG_FUNCTION_ARGS)
{
	text	   *package_name;
	text	   *var_name;
	Package    *package;
	Variable   *variable = NULL;
	char		key[NAMEDATALEN];
	bool		found = false;
	bool		res = false;

	CHECK_ARGS_FOR_NULL();

	package_name = PG_GETARG_TEXT_PP(0);
	var_name = PG_GETARG_TEXT_PP(1);

	package = getCachedPackage(package_name, false);

	if (package == NULL)
	{
		PG_FREE_IF_COPY(package_name, 0);
		PG_FREE_IF_COPY(var_name, 1);

		PG_RETURN_BOOL(false);
	}

	if (likely(cachedVariableMatches(var_name, package)))
	{
		PG_FREE_IF_COPY(package_name, 0);
		PG_FREE_IF_COPY(var_name, 1);

		PG_RETURN_BOOL(true);
	}

	getKeyFromName(var_name, key);

	if (package->varHashRegular)
		variable = (Variable *) hash_search(package->varHashRegular,
											key, HASH_FIND, &found);
	if (!found && package->varHashTransact)
		variable = (Variable *) hash_search(package->varHashTransact,
											key, HASH_FIND, &found);

	if (found && isVariableValid(variable))
	{
		LastPackage = package;
		LastVariable = variable;
		res = true;
	}

	PG_FREE_IF_COPY(package_name, 0);
	PG_FREE_IF_COPY(var_name, 1);

	PG_RETURN_BOOL(res);
}

/*
 * Check if package exists.
 */
Datum
package_exists(PG_FUNCTION_ARGS)
{
	text	   *package_name;
	bool		res;

	if (PG_ARGISNULL(0))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("package name can not be NULL")));

	package_name = PG_GETARG_TEXT_PP(0);

	res = getCachedPackage(package_name, false) != NULL;

	PG_FREE_IF_COPY(package_name, 0);
	PG_RETURN_BOOL(res);
}

/*
 * Remove a variable honouring transactional semantics.
 *
 * A transactional variable may already be referenced by changesStack, so it is
 * invalidated in place and its physical removal is deferred to the stack
 * machinery; deleting it from the hash table here would leave a dangling
 * ChangedObject that turns into a wild pointer once the freed entry is reused.
 * A regular variable is not tracked in changesStack and is removed outright.
 */
void
removeVariable(Variable *variable)
{
	Package    *package = variable->package;
	TransObject *transObject = &variable->transObject;

	check_record_callback_mutation(NULL, variable);

	/* Add package to changes list, so we can remove it if it becomes empty */
	ensureObjectSavedInCurrentTrans(&package->transObject, TRANS_PACKAGE);

	if (variable->is_transactional)
	{
		remove_variables_variable(&variables_stats, variable);
		ensureTombstoneSavedInCurrentTrans(variable, 0);
		variable->is_deleted = true;
		GetPackState(package)->trans_var_num--;
		if ((GetPackState(package)->trans_var_num + numOfRegVars(package)) == 0)
			GetActualState(package)->is_valid = false;
	}
	else
		removeObject(transObject, TRANS_VARIABLE);

	resetVariablesCache();
}

/*
 * Remove variable from package by name.
 */
Datum
remove_variable(PG_FUNCTION_ARGS)
{
	text	   *package_name;
	text	   *var_name;
	Package    *package;
	Variable   *variable;

	CHECK_ARGS_FOR_NULL();

	package_name = PG_GETARG_TEXT_PP(0);
	var_name = PG_GETARG_TEXT_PP(1);
	check_record_callback_text(package_name, var_name);

	package = getCachedPackage(package_name, true);
	variable = getCachedVariable(package, var_name, InvalidOid, false, true);

	removeVariable(variable);

	PG_FREE_IF_COPY(package_name, 0);
	PG_FREE_IF_COPY(var_name, 1);

	PG_RETURN_VOID();
}

/*
 * Remove package by name.
 */
Datum
remove_package(PG_FUNCTION_ARGS)
{
	Package    *package;
	text	   *package_name;

	if (PG_ARGISNULL(0))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("package name can not be NULL")));

	package_name = PG_GETARG_TEXT_PP(0);
	check_record_callback_text(package_name, NULL);

	package = getPackage(package_name, true);
	check_record_callback_mutation(package, NULL);
	/*
	 * Need to remove variables before removing package because
	 * remove_variables_package() calls hash_seq_term() which uses
	 * "entry->status->hashp->frozen" but memory context of "hashp"
	 * for regular variables can be deleted in removePackageInternal().
	 */
	remove_variables_package(&variables_stats, package);
	remove_packages_unmaterialized(&packages_stats);

	removePackageInternal(package);

	resetVariablesCache();

	PG_FREE_IF_COPY(package_name, 0);
	PG_RETURN_VOID();
}

static void
removePackageInternal(Package *package)
{
	TransObject *transObject = &package->transObject;

	/*
	 * Removing the package changes only its state. Do not mark individual
	 * records for reinitialization here: a package rollback would not restore
	 * those flags. createVariableInternal() marks a recreated variable instead.
	 *
	 * Record the package savepoint before deleting regular variable storage so
	 * an allocation failure leaves the package and its regular values intact.
	 */
	ensureObjectSavedInCurrentTrans(transObject, TRANS_PACKAGE);

	resetVariablesCache();

	/* All regular variables will be freed */
	if (package->hctxRegular)
	{
		MemoryContextDelete(package->hctxRegular);
		package->hctxRegular = NULL;
		package->varHashRegular = NULL;
	}

	GetActualState(package)->is_valid = false;
	GetPackState(package)->trans_var_num = 0;
	GetPackState(package)->is_removed = true;
#ifdef PGPRO_EE
	if (getNestLevelATX() > 0)
		GetPackState(package)->atx_removed = true;
#endif
}

/* Check if package has any valid variables */
static bool
isPackageEmpty(Package *package)
{
	int			var_num = GetPackState(package)->trans_var_num;

	if (package->varHashRegular)
		var_num += hash_get_num_entries(package->varHashRegular);

	return var_num == 0;
}

/*
 * Reset cache variables to their default values. It is necessary to do in case
 * of some changes: removing, rollbacking, etc.
 */
static void
resetVariablesCache(void)
{
	/* Remove package and variable from cache */
	LastPackage = NULL;
	LastVariable = NULL;
}

/*
 * Remove all packages and variables.
 * Memory context will be released after committing.
 */
Datum
remove_packages(PG_FUNCTION_ARGS)
{
	Package    *package;
	HASH_SEQ_STATUS pstat;

	check_record_callback_mutation(NULL, NULL);

	/* There is no any packages and variables */
	if (packagesHash == NULL)
		PG_RETURN_VOID();

	/*
	 * Need to remove variables before removing packages because
	 * remove_variables_all() calls hash_seq_term() which uses
	 * "entry->status->hashp->frozen" but memory context of "hashp"
	 * for regular variables can be deleted in removePackageInternal().
	 */
	remove_variables_all(&variables_stats);
	remove_packages_all(&packages_stats);

	/* Get packages list */
	hash_seq_init(&pstat, packagesHash);
	while ((package = (Package *) hash_seq_search(&pstat)) != NULL)
	{
		removePackageInternal(package);
	}

	resetVariablesCache();

	PG_RETURN_VOID();
}

/*
 * Structure for get_packages_and_variables().
 */
typedef struct
{
	char		package[NAMEDATALEN];
	char		variable[NAMEDATALEN];
	bool		is_transactional;
}			VariableRec;

/*
 * Get list of assigned packages and variables.
 */
Datum
get_packages_and_variables(PG_FUNCTION_ARGS)
{
	FuncCallContext *funcctx;
	VariableRec *recs;
	MemoryContext oldcontext;

	if (SRF_IS_FIRSTCALL())
	{
		TupleDesc	tupdesc;

		funcctx = SRF_FIRSTCALL_INIT();
		oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);

		/* Build a tuple descriptor for our result type */
		if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("function returning record called in context "
							"that cannot accept type record")));

		funcctx->tuple_desc = BlessTupleDesc(tupdesc);

		/*
		 * Get all packages and variables names and save them into
		 * funcctx->user_fctx.
		 */
		if (packagesHash)
		{
			Package    *package;
			HASH_SEQ_STATUS pstat;
			HASH_SEQ_STATUS vstat;
			volatile bool vstat_open = false;
			int			mRecs = NUMVARIABLES,
						nRecs = 0;

			recs = (VariableRec *) palloc(sizeof(VariableRec) * mRecs);

			/* Get packages list */
			hash_seq_init(&pstat, packagesHash);
			PG_TRY();
			{
				while ((package = (Package *) hash_seq_search(&pstat)) != NULL)
				{
					Variable   *variable;
					int			i;

					CHECK_FOR_INTERRUPTS();

					/* Skip packages marked as deleted */
					if (!GetActualState(package)->is_valid)
						continue;

					/* Get variables list for package */
					for (i = 0; i < 2; i++)
					{
						HTAB	   *htab = pack_htab(package, i);

						if (!htab)
							continue;
						hash_seq_init(&vstat, htab);
						vstat_open = true;
						while ((variable =
								(Variable *) hash_seq_search(&vstat)) != NULL)
						{
							CHECK_FOR_INTERRUPTS();

							if (!isVariableValid(variable))
								continue;

							/* Resize recs if necessary */
							if (nRecs >= mRecs)
							{
								mRecs *= 2;
								recs = (VariableRec *) repalloc(recs,
																sizeof(VariableRec) * mRecs);
							}

							strlcpy(recs[nRecs].package, GetName(package),
									NAMEDATALEN);
							strlcpy(recs[nRecs].variable, GetName(variable),
									NAMEDATALEN);
							recs[nRecs].is_transactional = variable->is_transactional;
							nRecs++;
						}
						vstat_open = false;
					}
				}
			}
			PG_CATCH();
			{
				if (vstat_open)
					hash_seq_term(&vstat);
				hash_seq_term(&pstat);
				PG_RE_THROW();
			}
			PG_END_TRY();

			funcctx->user_fctx = recs;
			funcctx->max_calls = nRecs;
		}
		else
			funcctx->max_calls = 0;

		MemoryContextSwitchTo(oldcontext);
	}

	funcctx = SRF_PERCALL_SETUP();

	/* Get the saved recs */
	recs = (VariableRec *) funcctx->user_fctx;

	if (funcctx->call_cntr < funcctx->max_calls)
	{
		Datum		values[3];
		bool		nulls[3];
		HeapTuple	tuple;
		Datum		result;
		int			i = funcctx->call_cntr;

		memset(nulls, 0, sizeof(nulls));

		values[0] = PointerGetDatum(cstring_to_text(recs[i].package));
		values[1] = PointerGetDatum(cstring_to_text(recs[i].variable));
		values[2] = recs[i].is_transactional;

		tuple = heap_form_tuple(funcctx->tuple_desc, values, nulls);
		result = HeapTupleGetDatum(tuple);

		SRF_RETURN_NEXT(funcctx, result);
	}
	else
		SRF_RETURN_DONE(funcctx);
}

static void
getMemoryTotalSpace(MemoryContext context, int level, Size *totalspace)
{
#if PG_VERSION_NUM >= 90600
	MemoryContext child;
	MemoryContextCounters totals;

	Assert(MemoryContextIsValid(context));

	/* Examine the context itself */
	memset(&totals, 0, sizeof(totals));
#if PG_VERSION_NUM >= 140000
	(*context->methods->stats) (context, NULL, NULL, &totals, true);
#elif PG_VERSION_NUM >= 110000
	(*context->methods->stats) (context, NULL, NULL, &totals);
#else
	(*context->methods->stats) (context, level, false, &totals);
#endif
	*totalspace += totals.totalspace;

	/*
	 * Examine children.
	 */
	for (child = context->firstchild; child != NULL; child = child->nextchild)
		getMemoryTotalSpace(child, level + 1, totalspace);
#else
	*totalspace = 0;
#endif
}

static Datum
package_stats_tuple_values(const char *name, Size used_memory,
						   TupleDesc tupdesc)
{
	Datum		values[2];
	bool		nulls[2] = {false, false};
	HeapTuple	tuple;

	values[0] = PointerGetDatum(cstring_to_text(name));
	values[1] = Int64GetDatum(used_memory);
	tuple = heap_form_tuple(tupdesc, values, nulls);
	pfree(DatumGetPointer(values[0]));
	return HeapTupleGetDatum(tuple);
}

static Datum
package_stats_tuple(Package *package, TupleDesc tupdesc)
{
	Size		regularSpace = 0,
				transactSpace = 0;

	if (package->hctxRegular)
		getMemoryTotalSpace(package->hctxRegular, 0, &regularSpace);
	if (package->hctxTransact)
		getMemoryTotalSpace(package->hctxTransact, 0, &transactSpace);
	return package_stats_tuple_values(GetName(package),
									  regularSpace + transactSpace,
									  tupdesc);
}

/* Get package memory statistics. */
Datum
get_packages_stats(PG_FUNCTION_ARGS)
{
	FuncCallContext *funcctx;
	MemoryContext oldcontext;
	HASH_SEQ_STATUS *rstat;
	Package    *package;
	PackageStatEntry *entry;

	if (SRF_IS_FIRSTCALL())
	{
		TupleDesc	tupdesc;

		funcctx = SRF_FIRSTCALL_INIT();
		oldcontext = MemoryContextSwitchTo(funcctx->multi_call_memory_ctx);

		/* Build a tuple descriptor for our result type */
		if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("function returning record called in context "
							"that cannot accept type record")));

		funcctx->tuple_desc = BlessTupleDesc(tupdesc);

		/*
		 * Get all packages and variables names and save them into
		 * funcctx->user_fctx.
		 */
		if (packagesHash)
		{
			check_open_seq_scans_limit();

			rstat = (HASH_SEQ_STATUS *) palloc0(sizeof(HASH_SEQ_STATUS));
			entry = palloc0(sizeof(PackageStatEntry));
			entry->status = NULL;
			entry->levels.level = GetCurrentTransactionNestLevel();
#ifdef PGPRO_EE
			entry->levels.atxlevel = getNestLevelATX();
#endif
			entry->user_fctx = &funcctx->user_fctx;
			entry->active = true;
			entry->callback.func = packageStatEntryShutdown;
			entry->callback.arg = entry;

			dlist_push_head(&packages_stats, &entry->node);

			MemoryContextRegisterResetCallback(funcctx->multi_call_memory_ctx,
											   &entry->callback);

			/* Get packages list */
			hash_seq_init(rstat, packagesHash);
			entry->status = rstat;
			funcctx->user_fctx = entry;
		}
		else
			funcctx->user_fctx = NULL;

		MemoryContextSwitchTo(oldcontext);
	}

	funcctx = SRF_PERCALL_SETUP();
	if (funcctx->user_fctx == NULL)
		SRF_RETURN_DONE(funcctx);

	/* Get packages list */
	entry = (PackageStatEntry *) funcctx->user_fctx;
	rstat = entry->status;
	if (!rstat)
	{
		PackageStatSnapshot *snap;

		if (entry->next_row == entry->num_rows)
			SRF_RETURN_DONE(funcctx);
		snap = &entry->rows[entry->next_row++];
		SRF_RETURN_NEXT(funcctx,
						package_stats_tuple_values(snap->name,
												   snap->used_memory,
												   funcctx->tuple_desc));
	}

	package = (Package *) hash_seq_search(rstat);
	if (package != NULL)
	{
		SRF_RETURN_NEXT(funcctx, package_stats_tuple(package, funcctx->tuple_desc));
	}
	else
	{
		remove_packages_status(&packages_stats, rstat);
		SRF_RETURN_DONE(funcctx);
	}
}

/*
 * Static functions
 */

static void
getKeyFromName(text *name, char *key)
{
	int			key_len = VARSIZE_ANY_EXHDR(name);

	if (key_len >= NAMEDATALEN - 1)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("name \"%.*s\" is too long",
						key_len, VARDATA_ANY(name))));

	strncpy(key, VARDATA_ANY(name), key_len);
	key[key_len] = '\0';
}

static void
ensurePackagesHashExists(void)
{
	HASHCTL		ctl;
	MemoryContext newcxt;
	HTAB	   *newhash = NULL;

	if (packagesHash)
		return;

	newcxt = AllocSetContextCreate(CacheMemoryContext,
								   PGV_MCXT_MAIN,
								   ALLOCSET_DEFAULT_SIZES);

	ctl.keysize = NAMEDATALEN;
	ctl.entrysize = sizeof(Package);
	ctl.hcxt = newcxt;

	PG_TRY();
	{
		newhash = hash_create("Packages hash",
							  NUMPACKAGES, &ctl,
							  HASH_ELEM |
#if PG_VERSION_NUM >= 140000
							  HASH_STRINGS |
#endif
							  HASH_CONTEXT);
	}
	PG_CATCH();
	{
		MemoryContextDelete(newcxt);
		PG_RE_THROW();
	}
	PG_END_TRY();

	ModuleContext = newcxt;
	packagesHash = newhash;
}

/*
 * Initialize a hash table with proper vars type
 */
static void
makePackHTAB(Package *package, bool is_trans)
{
	HASHCTL		ctl;
	char		hash_name[BUFSIZ];
	HTAB	  **htab;
	MemoryContext *context;
	MemoryContext newcxt;
	HTAB	   *newhash = NULL;

	htab = is_trans ? &package->varHashTransact : &package->varHashRegular;
	context = is_trans ? &package->hctxTransact : &package->hctxRegular;

	newcxt = AllocSetContextCreate(ModuleContext, PGV_MCXT_VARS,
								   ALLOCSET_DEFAULT_SIZES);

	snprintf(hash_name, BUFSIZ, "%s variables hash for package \"%s\"",
			 is_trans ? "Transactional" : "Regular", GetName(package));
	ctl.keysize = NAMEDATALEN;
	ctl.entrysize = sizeof(Variable);
	ctl.hcxt = newcxt;

	PG_TRY();
	{
		newhash = hash_create(hash_name, NUMVARIABLES, &ctl,
							  HASH_ELEM |
#if PG_VERSION_NUM >= 140000
							  HASH_STRINGS |
#endif
							  HASH_CONTEXT);
	}
	PG_CATCH();
	{
		MemoryContextDelete(newcxt);
		PG_RE_THROW();
	}
	PG_END_TRY();

	*context = newcxt;
	*htab = newhash;
}

static void
initObjectHistory(TransObject *object, TransObjectType type)
{
	/* Initialize history */
	TransState *state;
	MemoryContext statecontext = ModuleContext;
	int			size;
	Size		name_size;

	/*
	 * dynahash copies string keys only through their terminating NUL. Cache
	 * lookups can test a longer name, so initialize the remaining bytes before
	 * textNameEquals() reads key[name_len]. Keep this work out of cache lookups.
	 */
	name_size = strlen(object->name) + 1;
	MemSet(object->name + name_size, 0, sizeof(object->name) - name_size);

	size = (type == TRANS_PACKAGE ? sizeof(PackState) : sizeof(VarState));
	if (type == TRANS_VARIABLE)
	{
		Variable   *variable = (Variable *) object;

		/*
		 * A variable and all of its value storage are owned by the matching
		 * package context. Keep the initial state there too, so bulk package
		 * removal cannot leave an orphan VarState in ModuleContext.
		 */
		statecontext = pack_hctx(variable->package,
							 variable->is_transactional);
		Assert(statecontext != NULL);
	}
	dlist_init(&object->states);
	state = MemoryContextAllocZero(statecontext, size);
	dlist_push_head(&object->states, &(state->node));

	/* Initialize state */
	state->is_valid = true;
	if (type == TRANS_PACKAGE)
		((PackState *) state)->trans_var_num = 0;
	else
	{
		Variable   *variable = (Variable *) object;

		if (!variable->is_record)
		{
			VarState   *varState = (VarState *) state;
			ScalarVar  *scalar = &(varState->value.scalar);

			get_typlenbyval(variable->typid, &scalar->typlen,
							&scalar->typbyval);
			varState->value.scalar.is_null = true;
		}
	}
}

static Package *
getPackage(text *name, bool strict)
{
	Package    *package;
	char		key[NAMEDATALEN];
	bool		found;

	getKeyFromName(name, key);

	/* Find a package entry */
	if (packagesHash)
	{
		package = (Package *) hash_search(packagesHash, key, HASH_FIND, &found);

		if (found && GetActualState(package)->is_valid)
		{
			Assert(GetPackState(package)->trans_var_num +
				   numOfRegVars(package) > 0);
			return package;
		}
	}
	/* Package not found or it's current state is "invalid" */
	if (strict)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("unrecognized package \"%s\"", key)));

	return NULL;
}

static Package *
createPackage(text *name, bool is_trans)
{
	Package    *package;
	char		key[NAMEDATALEN];
	bool		found;

	getKeyFromName(name, key);
	ensurePackagesHashExists();

	/* Find or create a package entry */
	package = (Package *) hash_search(packagesHash, key, HASH_ENTER, &found);

	/*
	 * Looking up an existing valid package does not change transactional
	 * state.  Defer package savepoint/changesStack creation until a variable
	 * operation actually changes the package.
	 */
	if (found && GetActualState(package)->is_valid &&
		!GetPackState(package)->is_removed)
	{
		if (!pack_htab(package, is_trans))
			makePackHTAB(package, is_trans);
		return package;
	}

	if (found)
	{
		TransObject *transObj = &package->transObject;
		int			removal_level = GetPackState(package)->is_removed ?
			GetActualState(package)->levels.level : 0;

		ensureObjectSavedInCurrentTrans(transObj, TRANS_PACKAGE);

		if (!GetActualState(package)->is_valid || GetPackState(package)->is_removed)
		{
			HASH_SEQ_STATUS vstat;
			Variable   *variable;

			/*
			 * Record zero-copy tombstones for all transactional variables
			 * before clearing is_removed so no user callback runs on dead
			 * collections and a failed recreation leaves removal intact.
			 */
			if (package->varHashTransact)
			{
				hash_seq_init(&vstat, package->varHashTransact);
				PG_TRY();
				{
					while ((variable =
							(Variable *) hash_seq_search(&vstat)) != NULL)
					{
						ensureTombstoneSavedInCurrentTrans(variable,
														   removal_level);
					}
				}
				PG_CATCH();
				{
					hash_seq_term(&vstat);
					PG_RE_THROW();
				}
				PG_END_TRY();
			}

			GetActualState(package)->is_valid = true;
			GetPackState(package)->is_removed = false;
		}
	}
	else
	{
		MemoryContext oldcxt = CurrentMemoryContext;

		/* Package entry was created, so initialize it. */
		dlist_init(&package->transObject.states);
		package->varHashRegular = NULL;
		package->varHashTransact = NULL;
		package->hctxRegular = NULL;
		package->hctxTransact = NULL;
#ifdef PGPRO_EE
		package->context = NULL;
#endif
		PG_TRY();
		{
			initObjectHistory(&package->transObject, TRANS_PACKAGE);
			makePackHTAB(package, is_trans);
			addToChangesStack(&package->transObject, TRANS_PACKAGE);
		}
		PG_CATCH();
		{
			bool		removed;

			MemoryContextSwitchTo(oldcxt);
			if (package->hctxRegular)
				MemoryContextDelete(package->hctxRegular);
			if (package->hctxTransact)
				MemoryContextDelete(package->hctxTransact);
			while (!dlist_is_empty(&package->transObject.states))
				removeState(&package->transObject, TRANS_PACKAGE,
							GetActualState(&package->transObject));
			hash_search(packagesHash, package->transObject.name,
						HASH_REMOVE, &removed);
			resetVariablesCache();
			PG_RE_THROW();
		}
		PG_END_TRY();

		return package;
	}

	/* Create corresponding HTAB if not exists */
	if (!pack_htab(package, is_trans))
		makePackHTAB(package, is_trans);
	/* Add to changes list */
	if (!isObjectChangedInCurrentTrans(&package->transObject))
		addToChangesStack(&package->transObject, TRANS_PACKAGE);

	return package;
}

/*
 * Return a pointer to existing variable.
 * Function is useful to request a value of existing variable and
 * flag 'is_transactional' of this variable is unknown.
 */
static Variable *
getVariableInternal(Package *package, text *name, Oid typid, bool is_record,
					bool strict)
{
	Variable   *variable = NULL;
	char		key[NAMEDATALEN];
	bool		found = false;

	getKeyFromName(name, key);

	if (package->varHashRegular)
		variable = (Variable *) hash_search(package->varHashRegular,
											key, HASH_FIND, &found);
	if (!found && package->varHashTransact)
		variable = (Variable *) hash_search(package->varHashTransact,
											key, HASH_FIND, &found);

	/* A tombstone has no public value or requested type. */
	if (found && !isVariableValid(variable))
	{
		found = false;
		variable = NULL;
	}

	/* Check variable type */
	if (found)
	{
		if (typid != InvalidOid)
		{
			if (variable->typid != typid)
			{
				char	   *var_type = DatumGetCString(
													   DirectFunctionCall1(regtypeout,
																		   ObjectIdGetDatum(variable->typid)));

				ereport(ERROR,
						(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
						 errmsg("variable \"%s\" requires \"%s\" value",
								key, var_type)));
			}

			if (variable->is_record != is_record)
				ereport(ERROR,
						(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
						 errmsg("\"%s\" isn't a %s variable",
								key, is_record ? "record" : "scalar")));
		}
	}
	else
	{
		if (strict)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("unrecognized variable \"%s\"", key)));
	}

	return variable;
}

static bool
hasAnyValidState(Variable *variable)
{
	dlist_iter	iter;

	if (!variable->is_transactional)
		return isVariableValid(variable);

	dlist_foreach(iter, &variable->transObject.states)
	{
		TransState *state = dlist_container(TransState, node, iter.cur);

		if (state->is_valid)
			return true;
	}
	return false;
}

/*
 * Create a variable or return a pointer to existing one.
 * Function is useful to set new value to variable and flag 'is_transactional'
 * is known.
 */
static Variable *
createVariableInternal(Package *package, text *name, Oid typid, bool is_record,
					   bool is_transactional)
{
	Variable   *variable;
	TransObject *transObject;
	HTAB	   *htab;
	char		key[NAMEDATALEN];
	bool		found;

	getKeyFromName(name, key);
	check_record_callback_name(package, key);

	/*
	 * Reverse check: for non-transactional variable search in regular table
	 * and vice versa.
	 */
	htab = pack_htab(package, !is_transactional);
	if (htab)
	{
		Variable   *opp_var;

		opp_var = (Variable *) hash_search(htab, key, HASH_FIND, &found);
		if (found && hasAnyValidState(opp_var))
		{
			if (isPackageEmpty(package) &&
				isObjectChangedInCurrentTrans(&package->transObject))
				GetActualState(&package->transObject)->is_valid = false;
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("variable \"%s\" already created as %sTRANSACTIONAL",
							key, is_transactional ? "NOT " : "")));
		}
	}
#ifdef PGPRO_EE
	if (!is_transactional && !GetPackState(package)->atx_removed)
	{
		PackageContext *ctx;

		for (ctx = package->context; ctx != NULL; ctx = ctx->next)
		{
			if (ctx->child_committed_remove)
				break;
			if (ctx->varHashTransact != NULL &&
				!((PackState *) ctx->state)->is_removed)
			{
				Variable   *opp_var;

				opp_var = (Variable *) hash_search(ctx->varHashTransact, key,
												   HASH_FIND, &found);
				if (found && hasAnyValidState(opp_var))
				{
					if (isPackageEmpty(package) &&
						isObjectChangedInCurrentTrans(&package->transObject))
						GetActualState(&package->transObject)->is_valid = false;
					ereport(ERROR,
							(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
							 errmsg("variable \"%s\" already created as TRANSACTIONAL",
									key)));
				}
			}
		}
	}
#endif

	variable = (Variable *) hash_search(pack_htab(package, is_transactional),
										key, HASH_ENTER, &found);
	Assert(variable);
	transObject = &variable->transObject;

	/* Check variable type */
	if (found)
	{
		check_record_callback_mutation(NULL, variable);
		if (variable->typid != typid)
		{
			char	   *var_type = DatumGetCString(DirectFunctionCall1(regtypeout,
																	   ObjectIdGetDatum(variable->typid)));

			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("variable \"%s\" requires \"%s\" value",
							key, var_type)));
		}

		if (variable->is_record != is_record)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("\"%s\" isn't a %s variable",
							key, is_record ? "record" : "scalar")));

		/*
		 * Savepoint must be created when variable changed in current
		 * transaction. For each transaction level there should be a
		 * corresponding savepoint. New value should be stored in a last
		 * state.
		 */
		if (is_transactional)
			ensureObjectSavedInCurrentTrans(transObject, TRANS_VARIABLE);
	}
	else
	{
		MemoryContext oldcxt = CurrentMemoryContext;

		/* Variable entry was created, so initialize new variable. */
		dlist_init(&transObject->states);
		variable->typid = typid;
		variable->package = package;
		variable->is_record = is_record;
		variable->is_transactional = is_transactional;
		variable->is_deleted = false;
		PG_TRY();
		{
			initObjectHistory(transObject, TRANS_VARIABLE);

			if (!isObjectChangedInCurrentTrans(&package->transObject))
				ensureObjectSavedInCurrentTrans(&package->transObject,
												TRANS_PACKAGE);
			if (is_transactional)
				addToChangesStack(transObject, TRANS_VARIABLE);
		}
		PG_CATCH();
		{
			bool		removed;

			MemoryContextSwitchTo(oldcxt);
			while (!dlist_is_empty(&transObject->states))
				removeState(transObject, TRANS_VARIABLE,
							GetActualState(transObject));
			hash_search(pack_htab(package, is_transactional),
						transObject->name, HASH_REMOVE, &removed);
			if (isPackageEmpty(package) &&
				isObjectChangedInCurrentTrans(&package->transObject))
				GetActualState(&package->transObject)->is_valid = false;
			resetVariablesCache();
			PG_RE_THROW();
		}
		PG_END_TRY();

		if (is_transactional)
			GetPackState(package)->trans_var_num++;
		GetActualState(variable)->is_valid = true;
		return variable;
	}

	/*
	 * Revalidating a removed variable starts a new collection. This also covers
	 * package recreation, which invalidates the old variable states in
	 * createPackage(), without changing their flags at package removal time.
	 */
	if (!GetActualState(variable)->is_valid)
		variable->is_deleted = true;

	/*
	 * If the variable has been created or has just become valid, increment
	 * the counter of valid transactional variables. This mutates package
	 * state, so the package needs a savepoint at the current transaction level
	 * first. The new-variable branch above created one, but a revalidated
	 * variable (found && !is_valid) reaches here without it, and the fast
	 * package-lookup path skips createPackage(); without a package savepoint a
	 * ROLLBACK TO could not restore trans_var_num and would leave a phantom
	 * package.
	 */
	if (is_transactional &&
		(!found || !GetActualState(variable)->is_valid))
	{
		ensureObjectSavedInCurrentTrans(&package->transObject, TRANS_PACKAGE);
		GetPackState(package)->trans_var_num++;
	}
	GetActualState(variable)->is_valid = true;
	if (((VarState *) GetActualState(variable))->package_removal_level >=
		GetCurrentTransactionNestLevel())
		((VarState *) GetActualState(variable))->package_removal_level = 0;

	/* If it is necessary, put variable to changedVars */
	if (is_transactional)
		addToChangesStack(transObject, TRANS_VARIABLE);

	return variable;
}

static void
copyValue(VarState *src, VarState *dest, Variable *destVar)
{
	MemoryContext oldcxt;

	if (!src->state.is_valid)
	{
		if (!destVar->is_record)
		{
			dest->value.scalar = src->value.scalar;
			dest->value.scalar.value = 0;
			dest->value.scalar.is_null = true;
		}
		return;
	}

	oldcxt = MemoryContextSwitchTo(destVar->package->hctxTransact);

	if (destVar->is_record)
		/* copy record value */
	{
		HASH_SEQ_STATUS rstat;
		HashRecordEntry *item_src;
		RecordVar  *record_src = &src->value.record;
		RecordVar  *record_dest = &dest->value.record;

		init_record(record_dest, record_src->tupdesc, destVar);

		/* Copy previous history entry into the new one */
		hash_seq_init(&rstat, record_src->rhash);
		PG_TRY();
		{
			while ((item_src = (HashRecordEntry *) hash_seq_search(&rstat)) != NULL)
			{
				CHECK_FOR_INTERRUPTS();
				insert_record_copy(record_dest, item_src->tuple, destVar);
			}
		}
		PG_CATCH();
		{
			hash_seq_term(&rstat);
			PG_RE_THROW();
		}
		PG_END_TRY();
	}
	else
		/* copy scalar value */
	{
		ScalarVar  *scalar = &dest->value.scalar;

		*scalar = src->value.scalar;
		/* Until copying succeeds, the destination owns no Datum. */
		scalar->value = 0;
		if (!scalar->is_null)
			scalar->value = datumCopy(src->value.scalar.value,
									  scalar->typbyval, scalar->typlen);
		else
			scalar->value = 0;
	}

	MemoryContextSwitchTo(oldcxt);
}

static void
freeValue(VarState *varstate, bool is_record)
{
	if (is_record && varstate->value.record.hctx)
	{
		/* All records will be freed */
		MemoryContextDelete(varstate->value.record.hctx);
	}
	else if (!is_record && varstate->value.scalar.typbyval == false &&
			 varstate->value.scalar.is_null == false &&
			 varstate->value.scalar.value)
		pfree(DatumGetPointer(varstate->value.scalar.value));
}

static void
removeState(TransObject *object, TransObjectType type, TransState *stateToDelete)
{
	if (type == TRANS_VARIABLE)
	{
		Variable   *var = (Variable *) object;
		VarState   *varstate = (VarState *) stateToDelete;

		if (var->is_record && varstate->value.record.rhash)
			remove_variables_hash(&variables_stats, varstate->value.record.rhash);
		freeValue(varstate, var->is_record);
	}
	dlist_delete(&stateToDelete->node);
	pfree(stateToDelete);
}

/*
 * Advance active package statistics scans whose next bucket element is the
 * package entry about to be removed from packagesHash.
 */
static void
advance_package_stats_scans(Package *package)
{
	dlist_iter	iter;

	dlist_foreach(iter, &packages_stats)
	{
		PackageStatEntry *entry = dlist_container(PackageStatEntry, node,
												  iter.cur);
		HASH_SEQ_STATUS probe;

		if (!entry->active || !entry->status || !entry->status->curEntry)
			continue;

		probe = *entry->status;
		if ((Package *) hash_seq_search(&probe) == package)
			*entry->status = probe;
	}
}

/* Remove package or variable (either transactional or regular) */
bool
removeObject(TransObject *object, TransObjectType type)
{
	bool		found;
	HTAB	   *hash;
	Package    *package = NULL;

	if (type == TRANS_PACKAGE)
	{
#ifdef PGPRO_EE
		PackageContext *context,
				   *next;
#endif

		package = (Package *) object;

#ifdef PGPRO_EE
		/*
		 * Do not delete package inside autonomous transaction: it could be
		 * used in parent transaction. But we can delete package without any
		 * states: this means that the package was created in the current
		 * transaction.
		 */
		if (getNestLevelATX() > 0 && !dlist_is_empty(&object->states))
		{
			GetActualState(object)->is_valid = false;
			return false;
		}
#endif

		/* Terminate package scans before deleting variable hash contexts. */
		remove_variables_package(&variables_stats, package);
		advance_package_stats_scans(package);

		/* Regular variables had already removed */
		if (package->hctxRegular)
		{
			MemoryContextDelete(package->hctxRegular);
			package->hctxRegular = NULL;
			package->varHashRegular = NULL;
		}
		if (package->hctxTransact)
		{
			MemoryContextDelete(package->hctxTransact);
			package->hctxTransact = NULL;
			package->varHashTransact = NULL;
		}
#ifdef PGPRO_EE

		/*
		 * Remove contexts with transactional part (stored when switching to
		 * ATX transaction)
		 */
		context = package->context;
		while (context)
		{
			next = context->next;
			if (context->hctxTransact)
				MemoryContextDelete(context->hctxTransact);
			pfree(context);
			context = next;
		}
		package->context = NULL;
#endif
		hash = packagesHash;
	}
	else
	{
		Variable   *var = (Variable *) object;

		package = var->package;
		hash = var->is_transactional ?
			var->package->varHashTransact :
			var->package->varHashRegular;

		/* Terminate variable scans before deleting variable states. */
		remove_variables_variable(&variables_stats, var);
	}

	/* Remove all object's states */
	while (!dlist_is_empty(&object->states))
		removeState(object, type, GetActualState(object));

	/* HASH_REMOVE invalidates object, so finish accessing its states first. */
	hash_search(hash, object->name, HASH_REMOVE, &found);

	/* Remove package if it became empty */
	if (type == TRANS_VARIABLE && isPackageEmpty(package))
	{
		Assert(isObjectChangedInCurrentTrans(&package->transObject));
		GetActualState(&package->transObject)->is_valid = false;
	}

	resetVariablesCache();

	return true;
}

/*
 * Create a new state of object
 */
static void
createSavepoint(TransObject *object, TransObjectType type)
{
	TransState *newState,
			   *prevState;

	prevState = GetActualState(object);
	if (type == TRANS_PACKAGE)
	{
		newState = (TransState *) MemoryContextAllocZero(ModuleContext,
														 sizeof(PackState));
		((PackState *) newState)->trans_var_num = ((PackState *) prevState)->trans_var_num;
		((PackState *) newState)->is_removed = ((PackState *) prevState)->is_removed;
#ifdef PGPRO_EE
		((PackState *) newState)->atx_removed = ((PackState *) prevState)->atx_removed;
#endif
	}
	else
	{
		Variable   *var = (Variable *) object;
		MemoryContext oldcxt = CurrentMemoryContext;

		newState = (TransState *) MemoryContextAllocZero(var->package->hctxTransact,
														 sizeof(VarState));
		PG_TRY();
		{
			copyValue((VarState *) prevState, (VarState *) newState, var);
		}
		PG_CATCH();
		{
			MemoryContextSwitchTo(oldcxt);
			freeValue((VarState *) newState, var->is_record);
			pfree(newState);
			PG_RE_THROW();
		}
		PG_END_TRY();
	}
	dlist_push_head(&object->states, &newState->node);
	newState->is_valid = prevState->is_valid;
}

static void
ensureObjectSavedInCurrentTrans(TransObject *object, TransObjectType type)
{
	if (!isObjectChangedInCurrentTrans(object))
	{
		createSavepoint(object, type);
		PG_TRY();
		{
			addToChangesStack(object, type);
		}
		PG_CATCH();
		{
			removeState(object, type, GetActualState(object));
			PG_RE_THROW();
		}
		PG_END_TRY();
	}
}

static void
ensureTombstoneSavedInCurrentTrans(Variable *variable, int removal_level)
{
	TransObject *object = &variable->transObject;
	VarState   *vstate;

	if (!isObjectChangedInCurrentTrans(object))
	{
		VarState   *prevState = (VarState *) GetActualState(variable);

		vstate = (VarState *) MemoryContextAllocZero(variable->package->hctxTransact,
													 sizeof(VarState));
		if (!variable->is_record)
		{
			vstate->value.scalar = prevState->value.scalar;
			vstate->value.scalar.value = 0;
			vstate->value.scalar.is_null = true;
		}
		vstate->state.is_valid = false;
		dlist_push_head(&object->states, &vstate->state.node);
		PG_TRY();
		{
			addToChangesStack(object, TRANS_VARIABLE);
		}
		PG_CATCH();
		{
			removeState(object, TRANS_VARIABLE, &vstate->state);
			PG_RE_THROW();
		}
		PG_END_TRY();
	}
	else
	{
		vstate = (VarState *) GetActualState(variable);
		if (variable->is_record && vstate->value.record.rhash)
			remove_variables_hash(&variables_stats, vstate->value.record.rhash);
		freeValue(vstate, variable->is_record);
		if (variable->is_record)
			memset(&vstate->value.record, 0, sizeof(RecordVar));
		else
		{
			vstate->value.scalar.value = 0;
			vstate->value.scalar.is_null = true;
		}
		vstate->state.is_valid = false;
	}

	if (removal_level > 0 &&
		(vstate->package_removal_level == 0 ||
		 removal_level < vstate->package_removal_level))
		vstate->package_removal_level = removal_level;
}

static int
numOfRegVars(Package *package)
{
	if (package->varHashRegular)
		return hash_get_num_entries(package->varHashRegular);
	else
		return 0;
}

/*
 * Rollback object to its previous state
 */
static void
rollbackSavepoint(TransObject *object, TransObjectType type, bool sub)
{
	TransState *state;

	/* Nothing to do here if trans object was removed already. */
	if (dlist_is_empty(&object->states))
	{
		removeObject(object, type);
		return;
	}

	if (type == TRANS_VARIABLE && sub)
	{
		Variable   *variable = (Variable *) object;
		Package    *package = variable->package;
		VarState   *varstate = (VarState *) GetActualState(object);

		if (numOfRegVars(package) > 0 &&
			varstate->package_removal_level > 0 &&
			varstate->package_removal_level < GetCurrentTransactionNestLevel())
		{
			/* Regular recreation survives every intervening rollback. */
			if (variable->is_record && varstate->value.record.rhash)
				remove_variables_hash(&variables_stats,
									  varstate->value.record.rhash);
			freeValue(varstate, variable->is_record);
			if (variable->is_record)
				memset(&varstate->value.record, 0, sizeof(RecordVar));
			else
			{
				varstate->value.scalar.value = 0;
				varstate->value.scalar.is_null = true;
			}
			GetActualState(object)->is_valid = false;
			variable->is_deleted = true;
			releaseSavepoint(object, type, true);
			return;
		}
	}

	state = GetActualState(object);

	if (type == TRANS_PACKAGE)
	{
		Package    *package = (Package *) object;
		PackState  *packState = (PackState *) state;

		/*
		 * Unlink the current package state while retaining its ModuleContext
		 * allocation until we know no replacement PackState is needed.
		 * Reusing it in place keeps rollback completion allocation-free.
		 */
		dlist_delete(&state->node);

		/* If there is no more states... */
		if (dlist_is_empty(&object->states))
		{
			/* ...but object is a package and has some regular variables... */
			if (numOfRegVars(package) > 0)
			{
				/* ...reuse the unlinked state to keep the package valid. */
				packState->state.is_valid = true;
				packState->trans_var_num = 0;
				packState->is_removed = false;
#ifdef PGPRO_EE
				packState->atx_removed = false;
				/*
				 * Package inside autonomous transaction should not be detected
				 * as 'object has been changed in upper level' because in this
				 * case we will remove state in releaseSavepoint() but this
				 * state may be used in pgvRestoreContext(). So atxlevel should
				 * be 0 in case of rollback of autonomous transaction.
				 */
				packState->state.levels.atxlevel = sub ? getNestLevelATX() : 0;
#endif
				packState->state.levels.level = GetCurrentTransactionNestLevel() - 1;
				dlist_push_head(&object->states, &state->node);
				if (!dlist_is_empty(changesStack))
					addToChangesStackUpperLevel(object, type);
			}
			else
			{
				pfree(state);
				/* ...or remove an object if it is no longer needed. */
				removeObject(object, type);
			}
		}

		else if (numOfRegVars(package) > 0)
		{
			pfree(state);
			/*
			 * Regular values created after removal survive this rollback, while
			 * any transactional removal recorded on the exposed package state
			 * remains in effect until that removal level rolls back or ends.
			 */
			GetActualState(object)->is_valid = true;
		}

		/*
		 * But if a package has more states, but hasn't valid variables, mark
		 * it as not valid or remove at top level transaction.
		 */
		else if (isPackageEmpty(package))
		{
			if (dlist_is_empty(changesStack))
			{
				pfree(state);
				removeObject(object, type);
				return;
			}
			else if (!isObjectChangedInUpperTrans(object))
			{
				PackState  *prevState = GetPackState(package);

				packState->trans_var_num = prevState->trans_var_num;
				packState->is_removed = prevState->is_removed;
				packState->state.is_valid = false;
#ifdef PGPRO_EE
				packState->atx_removed = prevState->atx_removed;
				packState->state.levels.atxlevel = getNestLevelATX();
#endif
				packState->state.levels.level = GetCurrentTransactionNestLevel() - 1;
				dlist_push_head(&object->states, &state->node);
				addToChangesStackUpperLevel(object, type);
			}
			else
			{
				pfree(state);
				GetActualState(object)->is_valid = false;
			}
		}
		else
			pfree(state);
	}
	else
	{
		removeState(object, type, state);
		if (dlist_is_empty(&object->states))
			/* Remove a variable if it is no longer needed. */
			removeObject(object, type);
		else
			((Variable *) object)->is_deleted =
				!GetActualState(object)->is_valid;
	}
}

/*
 * Discard a transactional variable's current top-level transaction state on
 * COMMIT of an explicit transaction block.  This makes TRUE variables act as a
 * transaction-local overlay: creation disappears, updates revert to the
 * previous state, and removals restore the previous state.
 */
static void
discardTransactionalSavepoint(TransObject *object)
{
	Variable   *variable = (Variable *) object;
	Package    *package = variable->package;
	TransState *state;
	bool		current_valid;
	bool		restored_valid = false;

	Assert(variable->is_transactional);

	/* Nothing to do here if trans object was removed already. */
	if (dlist_is_empty(&object->states))
	{
		removeObject(object, TRANS_VARIABLE);
		return;
	}

	state = GetActualState(object);
	Assert(state->levels.level == GetCurrentTransactionNestLevel());
#ifdef PGPRO_EE
	Assert(state->levels.atxlevel == getNestLevelATX());
#endif

	current_valid = state->is_valid;
	if (dlist_has_next(&object->states, &state->node))
	{
		TransState *prev_state;

		prev_state = dlist_container(TransState, node, state->node.next);
		restored_valid = prev_state->is_valid;
	}

	removeState(object, TRANS_VARIABLE, state);

	if (current_valid != restored_valid)
	{
		if (current_valid)
		{
			Assert(GetPackState(package)->trans_var_num > 0);
			if (GetPackState(package)->trans_var_num > 0)
				GetPackState(package)->trans_var_num--;
		}
		else
			GetPackState(package)->trans_var_num++;
	}

	if (dlist_is_empty(&object->states))
	{
		removeObject(object, TRANS_VARIABLE);
		return;
	}

	variable->is_deleted = !restored_valid;
	GetActualState(&package->transObject)->is_valid = !isPackageEmpty(package);
}

/*
 * Remove previous state of object
 */
static void
releaseSavepoint(TransObject *object, TransObjectType type, bool sub)
{
	dlist_head *states = &object->states;

	Assert(GetActualState(object)->levels.level == GetCurrentTransactionNestLevel());
#ifdef PGPRO_EE
	Assert(GetActualState(object)->levels.atxlevel == getNestLevelATX());
#endif

	/*
	 * If the object is not valid and does not exist at a higher level (or if
	 * we complete the transaction) - remove object.
	 */
	if (!GetActualState(object)->is_valid &&
		(!dlist_has_next(states, dlist_head_node(states)) ||
		 dlist_is_empty(changesStack))
		)
	{
		if (removeObject(object, type))
			return;
	}

	/*
	 * If object has been changed in upper level - replace state of that level
	 * with the current one.
	 */
	if (isObjectChangedInUpperTrans(object))
	{
		TransState *stateToDelete;
		dlist_node *nodeToDelete;

		nodeToDelete = dlist_next_node(states, dlist_head_node(states));
		stateToDelete = dlist_container(TransState, node, nodeToDelete);
#ifdef PGPRO_EE
		/*
		 * We can not delete package state inside autonomous transaction
		 * because the state can be used in pgvRestoreContext().
		 * Exception: the state was created within this autonomous transaction.
		 */
		Assert(type != TRANS_PACKAGE || getNestLevelATX() == 0 ||
			   stateToDelete->levels.atxlevel == getNestLevelATX());
#endif
		if (type == TRANS_VARIABLE)
		{
			VarState   *curr_vs = (VarState *) GetActualState(object);
			VarState   *del_vs = (VarState *) stateToDelete;

			if (del_vs->package_removal_level > 0 &&
				(curr_vs->package_removal_level == 0 ||
				 del_vs->package_removal_level < curr_vs->package_removal_level))
				curr_vs->package_removal_level = del_vs->package_removal_level;
		}
		removeState(object, type, stateToDelete);
	}

	/*
	 * If the object does not yet have a record in previous level
	 * changesStack, create it.
	 */
	else if (!dlist_is_empty(changesStack))
		addToChangesStackUpperLevel(object, type);

	/* Change subxact level due to release */
	GetActualState(object)->levels.level--;
	if (type == TRANS_PACKAGE && dlist_is_empty(changesStack))
		GetPackState((Package *) object)->is_removed = false;
	if (type == TRANS_VARIABLE &&
		((VarState *) GetActualState(object))->package_removal_level >=
		GetActualState(object)->levels.level)
		((VarState *) GetActualState(object))->package_removal_level = 0;

#ifdef PGPRO_EE
	/* Change ATX level due to finish autonomous transaction */
	if (!sub && getNestLevelATX() > 0)
		GetActualState(object)->levels.atxlevel = 0;
#endif
}

/* Node currently being processed by applyAction(), spliced on promotion. */
static ChangedObject *active_changed_object = NULL;

static void
addToChangesStackUpperLevel(TransObject *object, TransObjectType type)
{
	ChangedObject *co_new;
	ChangesStackNode *csn;

	csn = dlist_head_element(ChangesStackNode, node, changesStack);
	if (likely(active_changed_object != NULL))
	{
		Assert(active_changed_object->object == object);
		co_new = active_changed_object;
		active_changed_object = NULL;
		dlist_delete(&co_new->node);
	}
	else
		co_new = makeChangedObject(object, changesStackContext);
	dlist_push_head(type == TRANS_PACKAGE ? csn->changedPacksList :
					csn->changedVarsList,
					&co_new->node);
}

/*
 * Check if object was changed in current transaction level
 */
static bool
isObjectChangedInCurrentTrans(TransObject *object)
{
	TransState *state;

	if (!changesStack)
		return false;

	state = GetActualState(object);
	return
#ifdef PGPRO_EE

	/*
	 * We should separate states with equal subxacts but with different ATX
	 * level
	 */
		state->levels.atxlevel == getNestLevelATX() &&
#endif
		state->levels.level == GetCurrentTransactionNestLevel();
}

/*
 * Check if object was changed in parent transaction level
 */
static bool
isObjectChangedInUpperTrans(TransObject *object)
{
	TransState *cur_state,
			   *prev_state;

	cur_state = GetActualState(object);
	if (dlist_has_next(&object->states, &cur_state->node) &&
#ifdef PGPRO_EE
		cur_state->levels.atxlevel == getNestLevelATX() &&
#endif
		cur_state->levels.level == GetCurrentTransactionNestLevel())
	{
		prev_state = dlist_container(TransState, node, cur_state->node.next);
		return
#ifdef PGPRO_EE

		/*
		 * We should separate states with equal subxacts but with different
		 * ATX level
		 */
			prev_state->levels.atxlevel == getNestLevelATX() &&
#endif
			prev_state->levels.level == GetCurrentTransactionNestLevel() - 1;
	}
	else
		return
#ifdef PGPRO_EE

		/*
		 * We should separate states with equal subxacts but with different
		 * ATX level
		 */
			cur_state->levels.atxlevel == getNestLevelATX() &&
#endif
			cur_state->levels.level == GetCurrentTransactionNestLevel() - 1;
}

/*
 * Create a new list of variables, changed in current transaction level
 */
static void
pushChangesStack(int level)
{
	MemoryContext oldcxt;
	ChangesStackNode *volatile csn = NULL;
	dlist_head *volatile new_stack = NULL;

	/*
	 * Initialize changesStack and create MemoryContext for it if not done
	 * before.
	 */
	if (!changesStackContext)
		changesStackContext = AllocSetContextCreate(ModuleContext,
													PGV_MCXT_STACK,
													ALLOCSET_START_SMALL_SIZES);
	Assert(changesStackContext);
	oldcxt = MemoryContextSwitchTo(changesStackContext);

	PG_TRY();
	{
		if (!changesStack)
		{
			new_stack = palloc0(sizeof(dlist_head));
			dlist_init(new_stack);
		}
		csn = palloc0(sizeof(ChangesStackNode));
		csn->changedVarsList = palloc0(sizeof(dlist_head));
		csn->changedPacksList = palloc0(sizeof(dlist_head));
	}
	PG_CATCH();
	{
		MemoryContextSwitchTo(oldcxt);
		if (csn)
		{
			if (csn->changedPacksList)
				pfree(csn->changedPacksList);
			if (csn->changedVarsList)
				pfree(csn->changedVarsList);
			pfree(csn);
		}
		if (new_stack)
			pfree(new_stack);
		if (!changesStack && changesStackContext)
		{
			MemoryContextDelete(changesStackContext);
			changesStackContext = NULL;
		}
		PG_RE_THROW();
	}
	PG_END_TRY();

	if (new_stack)
		changesStack = new_stack;
	csn->level = level;
	dlist_init(csn->changedVarsList);
	dlist_init(csn->changedPacksList);
	dlist_push_head(changesStack, &csn->node);

	MemoryContextSwitchTo(oldcxt);
}

/*
 * Create a changesStack with the required depth.
 */
static void
prepareChangesStack(void)
{
	if (!changesStack)
	{
		MemoryContext oldcxt = CurrentMemoryContext;
		int			depth = GetCurrentTransactionNestLevel();
		int			lvl;

		PG_TRY();
		{
			for (lvl = 1; lvl <= depth; lvl++)
			{
				pushChangesStack(lvl);
			}
		}
		PG_CATCH();
		{
			MemoryContextSwitchTo(oldcxt);
			if (changesStackContext)
				MemoryContextDelete(changesStackContext);
			changesStack = NULL;
			changesStackContext = NULL;
			PG_RE_THROW();
		}
		PG_END_TRY();
	}
}

/*
 * Initialize an instance of ChangedObject datatype
 */
static inline ChangedObject *
makeChangedObject(TransObject *object, MemoryContext ctx)
{
	ChangedObject *co;

	co = MemoryContextAllocZero(ctx, sizeof(ChangedObject));
	co->object = object;

	return co;
}

/*
 * Add an object to the list of created, removed, or changed objects
 * in current transaction level
 */
static void
addToChangesStack(TransObject *object, TransObjectType type)
{
	prepareChangesStack();

	if (!isObjectChangedInCurrentTrans(object))
	{
		ChangesStackNode *csn;
		ChangedObject *co;

		csn = get_actual_changes_list();
		co = makeChangedObject(object, changesStackContext);
		dlist_push_head(type == TRANS_PACKAGE ? csn->changedPacksList :
						csn->changedVarsList, &co->node);

		/* Give this object current subxact level */
		GetActualState(object)->levels.level = GetCurrentTransactionNestLevel();
#ifdef PGPRO_EE
		GetActualState(object)->levels.atxlevel = getNestLevelATX();
#endif
	}
}

/*
 * Possible actions on variables.
 * Savepoints are created in setters so we don't need a CREATE_SAVEPOINT action.
 */
typedef enum Action
{
	RELEASE_SAVEPOINT,
	ROLLBACK_TO_SAVEPOINT,
	DISCARD_TRANSACTIONAL_SAVEPOINT
}			Action;

/*
 * Apply savepoint actions on list of variables or packages.
 */
static void
applyAction(Action action, TransObjectType type, dlist_head *list, bool sub)
{
	while (!dlist_is_empty(list))
	{
		ChangedObject *co = dlist_container(ChangedObject, node,
											dlist_head_node(list));
		TransObject *object = co->object;

		active_changed_object = co;
		switch (action)
		{
			case ROLLBACK_TO_SAVEPOINT:
				rollbackSavepoint(object, type, sub);
				break;
			case RELEASE_SAVEPOINT:
			case DISCARD_TRANSACTIONAL_SAVEPOINT:

				/*
				 * If package was removed in current transaction level mark
				 * var as removed. We do not check pack_state->level, because
				 * var cannot get in list of changes until pack is removed.
				 */
				if (type == TRANS_VARIABLE)
				{
					Variable   *variable = (Variable *) object;
					Package    *package = variable->package;

					if (!GetActualState(package)->is_valid || GetPackState(package)->is_removed)
						GetActualState(variable)->is_valid = false;

					if (action == DISCARD_TRANSACTIONAL_SAVEPOINT &&
						variable->is_transactional &&
						!GetPackState(package)->is_removed)
					{
						discardTransactionalSavepoint(object);
						break;
					}
				}

				releaseSavepoint(object, type, sub);
				break;
		}
		if (active_changed_object != NULL)
		{
			dlist_delete(&active_changed_object->node);
			pfree(active_changed_object);
			active_changed_object = NULL;
		}
	}
}

/*
 * Iterate variables and packages from list of changes and
 * apply corresponding action on them
 */
static void
processChanges(Action action, bool sub)
{
	ChangesStackNode *bottom_list;

	Assert(changesStack && changesStackContext);

	/*
	 * Re-entrancy guard. If a previous processChanges() was interrupted by an
	 * error after it had already popped the bottom node -- leaving an empty but
	 * non-NULL stack -- the following XACT_EVENT_ABORT re-enters here. There is
	 * nothing left to apply, and popping an empty list would dereference its
	 * header as a node, so discard the spent stack and return.
	 */
	if (dlist_is_empty(changesStack))
	{
		MemoryContextDelete(changesStackContext);
		changesStack = NULL;
		changesStackContext = NULL;
		return;
	}

	/*
	 * ChangedObject nodes live in changesStackContext, so promotion to an upper
	 * stack level splices each node in place without allocating memory during
	 * savepoint release, rollback, or transaction abort.
	 */
	bottom_list = dlist_container(ChangesStackNode, node,
								  dlist_pop_head_node(changesStack));

	PG_TRY();
	{
		applyAction(action, TRANS_VARIABLE, bottom_list->changedVarsList, sub);
		applyAction(action, TRANS_PACKAGE, bottom_list->changedPacksList, sub);
	}
	PG_CATCH();
	{
		active_changed_object = NULL;
		resetVariablesCache();
		if (!dlist_is_empty(bottom_list->changedVarsList) ||
			!dlist_is_empty(bottom_list->changedPacksList))
			dlist_push_head(changesStack, &bottom_list->node);
		else
		{
			pfree(bottom_list->changedVarsList);
			pfree(bottom_list->changedPacksList);
			pfree(bottom_list);
		}
		PG_RE_THROW();
	}
	PG_END_TRY();

	resetVariablesCache();

	pfree(bottom_list->changedVarsList);
	pfree(bottom_list->changedPacksList);
	pfree(bottom_list);
	/* Remove the stack if it is empty */
	if (dlist_is_empty(changesStack))
	{
		MemoryContextDelete(changesStackContext);
		changesStack = NULL;
		changesStackContext = NULL;
	}
	if (!hash_get_num_entries(packagesHash))
	{
		/* Terminate package scans while packagesHash header is still valid. */
		remove_packages_all(&packages_stats);
		MemoryContextDelete(ModuleContext);
		packagesHash = NULL;
		ModuleContext = NULL;
		resetVariablesCache();
		changesStack = NULL;
		changesStackContext = NULL;
	}
}

/*
 * Refuse to run in a pooled backend of the Postgres Pro Enterprise built-in
 * connection pooler.
 *
 * Why. Variables live in the memory of the backend process. A pooled backend
 * serves several client sessions in turn, so one session would see the
 * variables of another.
 *
 * Where it checks. Only Enterprise 11-16: their built-in pooler clears
 * IsDedicatedBackend in a pooled backend. Enterprise 17 has no built-in
 * pooler, and the Enterprise 18 headers have no IsDedicatedBackend. Other
 * builds check nothing.
 *
 * What it misses. Proxima, the pooler extension of Enterprise 18, keeps a
 * client on one backend only in a dedicated session and does not see
 * pg_variables state: with Proxima the client runs
 * SET proxima.force_dedicated = true before using variables. External poolers
 * (pg_doorman, Odyssey, PgBouncer) are invisible to the server on any edition.
 */
static void
compatibility_check(void)
{
#if defined(PGPRO_EE) && PG_VERSION_NUM >= 110000 && PG_VERSION_NUM < 170000
	if (!IsDedicatedBackend)
	{
		freeStatsLists();
		elog(ERROR, "pg_variables extension is incompatible with connection pooling");
	}
#endif							/* PGPRO_EE */
}

static bool
shouldDiscardTransactionalOnCommit(void)
{
#ifdef PGPRO_EE
	if (getNestLevelATX() > 0)
		return false;
#endif

	return true;
}

#ifdef PGPRO_EE
/*
 * At the beginning of ATX store the pg_variables's env into
 * pgv_context.
 */
static void
pgvSaveContext(void)
{
	Package    *package;
	HASH_SEQ_STATUS pstat;
	PgvContextStruct *sus;
	Package   **saved_pkgs = NULL;
	volatile long n_saved = 0;

	sus = MemoryContextAlloc(CurTransactionContext, sizeof(PgvContextStruct));

	/*
	 * Allocate all PackageContext nodes before detaching parent transactional
	 * hashes so an allocation failure rolls back cleanly without partial save.
	 */
	if (packagesHash != NULL)
	{
		long		total_pkgs = hash_get_num_entries(packagesHash);
		PackageContext *volatile pending_ctx = NULL;

		if (total_pkgs > 0)
			saved_pkgs = MemoryContextAlloc(CurTransactionContext,
											mul_size(sizeof(Package *), total_pkgs));

		hash_seq_init(&pstat, packagesHash);
		PG_TRY();
		{
			while ((package = (Package *) hash_seq_search(&pstat)) != NULL)
			{
				PackState  *atx_state;

				pending_ctx = MemoryContextAllocZero(ModuleContext,
													 sizeof(PackageContext));
				atx_state = MemoryContextAllocZero(ModuleContext,
												   sizeof(PackState));

				pending_ctx->next = package->context;
				pending_ctx->hctxTransact = package->hctxTransact;
				pending_ctx->varHashTransact = package->varHashTransact;
				pending_ctx->state = GetActualState(&package->transObject);
				pending_ctx->atx_state = &atx_state->state;
				package->context = pending_ctx;
				saved_pkgs[n_saved++] = package;
				pending_ctx = NULL;
			}
		}
		PG_CATCH();
		{
			long		i;

			hash_seq_term(&pstat);
			if (pending_ctx != NULL)
				pfree(pending_ctx);
			for (i = 0; i < n_saved; i++)
			{
				PackageContext *ctx = saved_pkgs[i]->context;

				saved_pkgs[i]->context = ctx->next;
				pfree(ctx->atx_state);
				pfree(ctx);
			}
			PG_RE_THROW();
		}
		PG_END_TRY();

		while (n_saved > 0)
		{
			PackState  *atx_state;

			package = saved_pkgs[--n_saved];
			atx_state = (PackState *) package->context->atx_state;
			atx_state->state.is_valid = (numOfRegVars(package) > 0);
			atx_state->state.levels.level = 0;
			atx_state->state.levels.atxlevel = getNestLevelATX();
			atx_state->trans_var_num = 0;
			atx_state->is_removed = false;
			atx_state->atx_removed = false;
			dlist_push_head(&package->transObject.states, &atx_state->state.node);
			package->context->atx_state = NULL;
			package->hctxTransact = NULL;
			package->varHashTransact = NULL;
		}
		if (saved_pkgs)
			pfree(saved_pkgs);
	}

	sus->changesStack = changesStack;
	changesStack = NULL;
	sus->changesStackContext = changesStackContext;
	changesStackContext = NULL;
	sus->atxlevel = active_atx_level;

	sus->next = pgv_context;
	pgv_context = sus;
	active_atx_level = getNestLevelATX();

	/* Remove stats for all transactional variables */
	remove_variables_transactional(&variables_stats);
	resetVariablesCache();
}

static void
purgeVariableFromChangesStack(dlist_head *stack, Variable *variable)
{
	dlist_iter	siter;

	if (stack == NULL)
		return;

	dlist_foreach(siter, stack)
	{
		ChangesStackNode *csn = dlist_container(ChangesStackNode, node,
												siter.cur);
		dlist_mutable_iter citer;

		dlist_foreach_modify(citer, csn->changedVarsList)
		{
			ChangedObject *co = dlist_container(ChangedObject, node,
												citer.cur);

			if ((Variable *) co->object == variable)
			{
				dlist_delete(citer.cur);
				pfree(co);
			}
		}
	}
}

static void
purgePackageVarsFromChangesStack(dlist_head *stack, Package *package)
{
	dlist_iter	siter;

	if (stack == NULL)
		return;

	dlist_foreach(siter, stack)
	{
		ChangesStackNode *csn = dlist_container(ChangesStackNode, node,
												siter.cur);
		dlist_mutable_iter citer;

		dlist_foreach_modify(citer, csn->changedVarsList)
		{
			ChangedObject *co = dlist_container(ChangedObject, node,
												citer.cur);

			if (((Variable *) co->object)->package == package)
			{
				dlist_delete(citer.cur);
				pfree(co);
			}
		}
	}
}

static bool
isPackageInChangesStack(dlist_head *stack, Package *package)
{
	dlist_iter	siter;

	if (stack == NULL)
		return false;

	dlist_foreach(siter, stack)
	{
		ChangesStackNode *csn = dlist_container(ChangesStackNode, node,
												siter.cur);
		dlist_iter	citer;

		dlist_foreach(citer, csn->changedPacksList)
		{
			ChangedObject *co = dlist_container(ChangedObject, node,
												citer.cur);

			if ((Package *) co->object == package)
				return true;
		}
		dlist_foreach(citer, csn->changedVarsList)
		{
			ChangedObject *co = dlist_container(ChangedObject, node,
												citer.cur);

			if (((Variable *) co->object)->package == package)
				return true;
		}
	}
	return false;
}

static void
invalidateParentPackageInATXRestore(Package *package, int parent_atxlevel,
									dlist_head *parent_stack)
{
	TransObject *object = &package->transObject;
	dlist_iter	piter;

	if (package->hctxTransact != NULL)
	{
		remove_variables_transactional(&variables_stats);
		purgePackageVarsFromChangesStack(parent_stack, package);
		MemoryContextDelete(package->hctxTransact);
		package->hctxTransact = NULL;
		package->varHashTransact = NULL;
	}

	dlist_foreach(piter, &object->states)
	{
		PackState  *ps = dlist_container(PackState, state.node, piter.cur);

		if (ps->state.levels.atxlevel != parent_atxlevel)
			break;
		ps->trans_var_num = 0;
		ps->is_removed = true;
		ps->state.is_valid = (numOfRegVars(package) > 0);
		if (parent_atxlevel > 0)
			ps->atx_removed = true;
	}
}

static void
deduplicateRestoredTransactVars(Package *package, int parent_atxlevel,
								dlist_head *parent_stack)
{
	HASH_SEQ_STATUS rstat;
	Variable   *reg_var;

	if (package->varHashRegular == NULL || package->varHashTransact == NULL)
		return;

	hash_seq_init(&rstat, package->varHashRegular);
	while ((reg_var = (Variable *) hash_seq_search(&rstat)) != NULL)
	{
		Variable   *tx_var;
		bool		found;
		bool		removed;
		dlist_iter	piter;

		tx_var = (Variable *) hash_search(package->varHashTransact,
										  GetName(reg_var),
										  HASH_FIND, &found);
		if (!found)
			continue;

		dlist_foreach(piter, &package->transObject.states)
		{
			PackState  *ps = dlist_container(PackState, state.node,
											 piter.cur);
			dlist_iter	viter;
			bool		was_valid = false;

			if (ps->state.levels.atxlevel != parent_atxlevel)
				break;

			dlist_foreach(viter, &tx_var->transObject.states)
			{
				VarState   *vs = dlist_container(VarState, state.node,
												 viter.cur);

				if (vs->state.levels.level <= ps->state.levels.level)
				{
					was_valid = vs->state.is_valid;
					break;
				}
			}
			if (was_valid && ps->trans_var_num > 0)
				ps->trans_var_num--;
			ps->state.is_valid = (ps->trans_var_num + numOfRegVars(package) > 0);
		}

		remove_variables_variable(&variables_stats, tx_var);
		purgeVariableFromChangesStack(parent_stack, tx_var);
		while (!dlist_is_empty(&tx_var->transObject.states))
			removeState(&tx_var->transObject, TRANS_VARIABLE,
						GetActualState(tx_var));
		hash_search(package->varHashTransact, GetName(tx_var),
					HASH_REMOVE, &removed);
	}
}

/*
 * Restore pg_variables's env pointer from pgv_context.
 */
static void
pgvRestoreContext(bool committed)
{
	Package    *package;
	HASH_SEQ_STATUS pstat;
	PgvContextStruct *sus = pgv_context;
	int			parent_atxlevel = sus ? sus->atxlevel : getNestLevelATX() - 1;
	dlist_head *parent_stack = sus ? sus->changesStack : NULL;

	if (getNestLevelATX() > active_atx_level)
		return;

	resetVariablesCache();
	/* Delete changes stack for all transactional variables */
	if (changesStackContext)
	{
		MemoryContextDelete(changesStackContext);
		changesStack = NULL;
		changesStackContext = NULL;
	}
	/* We just finished ATX => need to free all hash_seq_search scans */
	freeStatsLists();

	/* Restore transactional variables for all packages */
	if (packagesHash != NULL)
	{
		/* Get packages list */
		hash_seq_init(&pstat, packagesHash);
		while ((package = (Package *) hash_seq_search(&pstat)) != NULL)
		{
			/*
			 * Delete context with transactional variables (they are no need
			 * outside ATX transaction)
			 */
			if (package->hctxTransact)
				MemoryContextDelete(package->hctxTransact);

			/* We have stored context for this package? */
			if (package->context)
			{
				PackageContext *context = package->context;
				PackageContext *next = context->next;
				TransObject *object = &package->transObject;
				TransState *state;
				bool		atx_removed = GetPackState(package)->atx_removed;
				bool		effective_remove = context->child_committed_remove ||
					(committed && atx_removed);

				/* Restore transactional variables from context */
				package->hctxTransact = context->hctxTransact;
				package->varHashTransact = context->varHashTransact;

				/* Remove all package states, generated in ATX transaction */
				while ((state = GetActualState(object)) != context->state)
				{
					removeState(object, TRANS_PACKAGE, state);
					if (dlist_is_empty(&object->states))
						elog(ERROR, "pg_variables extension can not find "
							 "transaction state for package");
				}

				pfree(context);
				package->context = next;

				if (effective_remove)
				{
					if (package->context != NULL)
						package->context->child_committed_remove = true;
					invalidateParentPackageInATXRestore(package,
														parent_atxlevel,
														parent_stack);
				}
				else
					deduplicateRestoredTransactVars(package,
													parent_atxlevel,
													parent_stack);

				GetActualState(object)->is_valid =
					(GetPackState(package)->trans_var_num + numOfRegVars(package) > 0);

				/*
				 * A committed level-0 package emptied inside ATX has no parent
				 * changesStack entry to release it later, so drop it now.
				 */
				if (!GetActualState(object)->is_valid &&
					package->context == NULL &&
					numOfRegVars(package) == 0 &&
					(package->varHashTransact == NULL ||
					 hash_get_num_entries(package->varHashTransact) == 0) &&
					!isPackageInChangesStack(parent_stack, package) &&
					!dlist_has_next(&object->states, dlist_head_node(&object->states)) &&
					GetActualState(object)->levels.level == 0)
				{
					while (!dlist_is_empty(&object->states))
						removeState(object, TRANS_PACKAGE, GetActualState(object));
					removeObject(object, TRANS_PACKAGE);
				}
			}
			else
			{
				/* Package was created in this autonomous transaction */
				package->hctxTransact = NULL;
				package->varHashTransact = NULL;
				GetPackState(package)->trans_var_num = 0;
				GetPackState(package)->is_removed = false;
				GetPackState(package)->atx_removed = false;
				GetActualState(package)->is_valid = numOfRegVars(package) > 0;

				/*
				 * A new empty package has no parent state to restore. Remove
				 * its history first so removeObject() can release it inside ATX.
				 */
				if (!GetActualState(package)->is_valid)
				{
					TransObject *object = &package->transObject;

					while (!dlist_is_empty(&object->states))
						removeState(object, TRANS_PACKAGE, GetActualState(object));
					removeObject(object, TRANS_PACKAGE);
				}
			}
		}
	}

	/*
	 * 'sus' can be NULL in case pg_variables was not initialized at start of
	 * transaction
	 */
	if (sus)
	{
		/* Restore changes stack for previous level: */
		changesStack = sus->changesStack;
		changesStackContext = sus->changesStackContext;
		active_atx_level = sus->atxlevel;

		pgv_context = sus->next;
		pfree(sus);
	}
	else
		active_atx_level = getNestLevelATX() - 1;

	if (changesStack == NULL && pgv_context == NULL &&
		packagesHash != NULL && !hash_get_num_entries(packagesHash))
	{
		remove_packages_all(&packages_stats);
		MemoryContextDelete(ModuleContext);
		packagesHash = NULL;
		ModuleContext = NULL;
		resetVariablesCache();
	}
}
#endif							/* PGPRO_EE */

/*
 * Finish child-level hash registrations before the server discards them.
 * Record scans retain entry pointers, protected from deletion by the full-scan
 * guard. Stats scans retain result rows because package entries can disappear.
 */
static bool
has_child_hash_scan(HTAB *hash, Levels *levels)
{
	dlist_iter	iter;

	dlist_foreach(iter, &variables_stats)
	{
		VariableStatEntry *entry = dlist_container(VariableStatEntry, node,
												   iter.cur);

		if (entry->active && entry->status && entry->hash == hash &&
			VariableStatEntry_level_eq(entry, levels))
			return true;
	}
	return false;
}

static void
preserve_subtransaction_scans(Levels *levels)
{
	dlist_iter	iter;
	bool		preserve_pkg_stats = false;

	/*
	 * Materialize every open scan on a hash table that has a child-level scan
	 * at this savepoint so dynahash's table-keyed deregister_seq_scan() cannot
	 * swap child and ancestor scan levels in seq_scan_tables[].
	 *
	 * Pass 1 allocates all snapshot buffers before any hash_seq_search() call
	 * mutates entry->status or seq_scan_tables[]. Pass 2 drains the marked
	 * scans without allocating or raising errors.
	 */
	dlist_foreach(iter, &variables_stats)
	{
		VariableStatEntry *entry = dlist_container(VariableStatEntry, node,
												   iter.cur);
		MemoryContext context;

		entry->materialize = false;
		if (!entry->active || !entry->status ||
#ifdef PGPRO_EE
			entry->levels.atxlevel != levels->atxlevel ||
#endif
			!has_child_hash_scan(entry->hash, levels))
			continue;

		if (entry->rows != NULL)
		{
			pfree(entry->rows);
			entry->rows = NULL;
		}
		entry->num_rows = 0;
		entry->next_row = 0;
		context = GetMemoryChunkContext(entry);
		entry->rows = MemoryContextAlloc(context,
										mul_size(sizeof(HashRecordEntry *),
												 hash_get_num_entries(entry->hash)));
		entry->materialize = true;
	}

	dlist_foreach(iter, &packages_stats)
	{
		PackageStatEntry *entry = dlist_container(PackageStatEntry, node,
												  iter.cur);

		entry->materialize = false;
		if (entry->active && entry->status &&
			PackageStatEntry_level_eq(entry, levels))
			preserve_pkg_stats = true;
	}

	if (preserve_pkg_stats)
	{
		Size		snap_bytes = mul_size(sizeof(PackageStatSnapshot),
										  hash_get_num_entries(packagesHash));

		dlist_foreach(iter, &packages_stats)
		{
			PackageStatEntry *entry = dlist_container(PackageStatEntry, node,
													  iter.cur);
			MemoryContext context;

			if (!entry->active || !entry->status
#ifdef PGPRO_EE
				|| entry->levels.atxlevel != levels->atxlevel
#endif
				)
				continue;

			if (entry->rows != NULL)
			{
				pfree(entry->rows);
				entry->rows = NULL;
			}
			entry->num_rows = 0;
			entry->next_row = 0;
			context = GetMemoryChunkContext(entry);
			entry->rows = MemoryContextAlloc(context, snap_bytes);
			entry->materialize = true;
		}
	}

	dlist_foreach(iter, &variables_stats)
	{
		VariableStatEntry *entry = dlist_container(VariableStatEntry, node,
												   iter.cur);
		HashRecordEntry *item;

		if (!entry->materialize)
			continue;

		while ((item = hash_seq_search(entry->status)) != NULL)
			entry->rows[entry->num_rows++] = item;
		entry->status = NULL;
		entry->materialize = false;
	}

	if (preserve_pkg_stats)
	{
		dlist_foreach(iter, &packages_stats)
		{
			PackageStatEntry *entry = dlist_container(PackageStatEntry, node,
													  iter.cur);
			Package    *package;

			if (!entry->materialize)
				continue;

			while ((package = hash_seq_search(entry->status)) != NULL)
			{
				Size		regularSpace = 0,
							transactSpace = 0;
				PackageStatSnapshot *snap = &entry->rows[entry->num_rows++];

				strlcpy(snap->name, GetName(package), NAMEDATALEN);
				if (package->hctxRegular)
					getMemoryTotalSpace(package->hctxRegular, 0, &regularSpace);
				if (package->hctxTransact)
					getMemoryTotalSpace(package->hctxTransact, 0, &transactSpace);
				snap->used_memory = regularSpace + transactSpace;
			}
			entry->status = NULL;
			entry->materialize = false;
		}
	}
}

static void
promote_subtransaction_scans(Levels *levels)
{
	dlist_iter	iter;

	dlist_foreach(iter, &variables_stats)
	{
		VariableStatEntry *entry = dlist_container(VariableStatEntry, node,
												   iter.cur);

		if (VariableStatEntry_level_eq(entry, levels))
			entry->levels.level--;
	}
	dlist_foreach(iter, &packages_stats)
	{
		PackageStatEntry *entry = dlist_container(PackageStatEntry, node,
												  iter.cur);

		if (PackageStatEntry_level_eq(entry, levels))
			entry->levels.level--;
	}
}

/* Intercept execution during subtransaction processing. */
static void
pgvSubTransCallback(SubXactEvent event, SubTransactionId mySubid,
					SubTransactionId parentSubid, void *arg)
{
	Levels		levels;

	levels.level = GetCurrentTransactionNestLevel();
#ifdef PGPRO_EE
	levels.atxlevel = getNestLevelATX();
#endif
	if (event == SUBXACT_EVENT_PRE_COMMIT_SUB)
		preserve_subtransaction_scans(&levels);

	if (changesStack)
	{
		switch (event)
		{
			case SUBXACT_EVENT_START_SUB:
				compatibility_check();
				pushChangesStack(levels.level);
				break;
			case SUBXACT_EVENT_COMMIT_SUB:
				if (dlist_is_empty(changesStack) ||
					get_actual_changes_list()->level == levels.level)
					processChanges(RELEASE_SAVEPOINT, true);
				break;
			case SUBXACT_EVENT_ABORT_SUB:
				if (dlist_is_empty(changesStack) ||
					get_actual_changes_list()->level == levels.level)
					processChanges(ROLLBACK_TO_SAVEPOINT, true);
				break;
			case SUBXACT_EVENT_PRE_COMMIT_SUB:
				break;
			default:
				/*
				 * Ignore any other subtransaction events. Tantor SE adds
				 * SUBXACT_EVENT_PRE_ABORT_SUB to the enum; there is nothing to
				 * do for it here, and the default keeps the build warning-free.
				 */
				break;
		}
	}

	if (event == SUBXACT_EVENT_COMMIT_SUB)
		promote_subtransaction_scans(&levels);
	else if (event == SUBXACT_EVENT_ABORT_SUB)
	{
		remove_variables_level(&variables_stats, &levels);
		remove_packages_level(&packages_stats, &levels);
	}
}

/*
 * Intercept execution during transaction processing
 */
static void
pgvTransCallback(XactEvent event, void *arg)
{
	bool		owns_current_atx = true;

#ifdef PGPRO_EE
	owns_current_atx = (getNestLevelATX() <= active_atx_level);
#endif

	if (owns_current_atx && changesStack)
	{
		switch (event)
		{
			case XACT_EVENT_PRE_COMMIT:
				compatibility_check();
				processChanges(shouldDiscardTransactionalOnCommit() ?
							   DISCARD_TRANSACTIONAL_SAVEPOINT :
							   RELEASE_SAVEPOINT, false);
				break;
			case XACT_EVENT_ABORT:
				while (changesStack)
					processChanges(ROLLBACK_TO_SAVEPOINT, false);
				break;
			case XACT_EVENT_PARALLEL_PRE_COMMIT:
				processChanges(shouldDiscardTransactionalOnCommit() ?
							   DISCARD_TRANSACTIONAL_SAVEPOINT :
							   RELEASE_SAVEPOINT, false);
				break;
			case XACT_EVENT_PARALLEL_ABORT:
				while (changesStack)
					processChanges(ROLLBACK_TO_SAVEPOINT, false);
				break;
			case XACT_EVENT_PRE_PREPARE:

				/* Pending package and variable histories cannot participate in 2PC. */
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("cannot PREPARE a transaction with pending pg_variables state changes"),
						 errdetail("Backend-local package and variable state is not transferred by two-phase commit.")));
				break;
			default:
				break;
		}
	}

	if (owns_current_atx &&
		(event == XACT_EVENT_PRE_COMMIT || event == XACT_EVENT_ABORT))
		freeStatsLists();

#ifdef PGPRO_EE
	if (getNestLevelATX() > 0)
	{
		if (event == XACT_EVENT_START)
		{						/* on each ATX transaction start */
			pgvSaveContext();
		}
		else if (owns_current_atx &&
				 (event == XACT_EVENT_ABORT || event == XACT_EVENT_PARALLEL_ABORT ||
				  event == XACT_EVENT_COMMIT || event == XACT_EVENT_PARALLEL_COMMIT ||
				  event == XACT_EVENT_PREPARE))
		{						/* on each ATX transaction finish */
			bool		committed = (event == XACT_EVENT_COMMIT ||
									 event == XACT_EVENT_PARALLEL_COMMIT);

			pgvRestoreContext(committed);
		}
	}
#endif
}

static void
variableStatEntryShutdown(void *arg)
{
	VariableStatEntry *entry = (VariableStatEntry *) arg;
	RemoveIfContext ctx;

	if (!entry->active)
		return;

	ctx.list = &variables_stats;
	ctx.value = entry;
	ctx.eq = VariableStatEntry_ptr_eq;
	ctx.getter = VariableStatEntry_status_ptr;
	ctx.match_first = true;
	ctx.term = true;
	ctx.clear_fctx = VariableStatEntry_clear_fctx;
	ctx.deactivate = VariableStatEntry_deactivate;
	if (!list_remove_if(ctx))
	{
		if (entry->status)
#ifdef PGPRO_EE
			hash_seq_term_all_levels(entry->status);
#else
			hash_seq_term(entry->status);
#endif
		VariableStatEntry_clear_fctx(entry);
		VariableStatEntry_deactivate(entry);
	}
}

static void
packageStatEntryShutdown(void *arg)
{
	PackageStatEntry *entry = (PackageStatEntry *) arg;
	RemoveIfContext ctx;

	if (!entry->active)
		return;

	ctx.list = &packages_stats;
	ctx.value = entry;
	ctx.eq = PackageStatEntry_ptr_eq;
	ctx.getter = PackageStatEntry_status_ptr;
	ctx.match_first = true;
	ctx.term = true;
	ctx.clear_fctx = PackageStatEntry_clear_fctx;
	ctx.deactivate = PackageStatEntry_deactivate;
	if (!list_remove_if(ctx))
	{
		if (entry->status)
#ifdef PGPRO_EE
			hash_seq_term_all_levels(entry->status);
#else
			hash_seq_term(entry->status);
#endif
		PackageStatEntry_clear_fctx(entry);
		PackageStatEntry_deactivate(entry);
	}
}

/*
 * End the hash_seq_search scans at the end of a transaction.
 *
 * Each scan is unregistered and dropped from its list, and its
 * set-returning function returns no more rows.
 *
 * In an autonomous transaction of Postgres Pro Enterprise only the scans
 * started in it or in its nested autonomous transactions end. The parent
 * transaction goes on after the autonomous one, and so do its scans: a
 * FOR loop over pgv_select() with an autonomous block in the body sees all
 * the rows.
 */
static void
freeStatsLists(void)
{
	dlist_mutable_iter iter;

#ifdef PGPRO_EE
	if (getNestLevelATX() > 0)
	{
		remove_variables_atxlevel(&variables_stats, getNestLevelATX());
		remove_packages_atxlevel(&packages_stats, getNestLevelATX());
		return;
	}
#endif

	dlist_foreach_modify(iter, &variables_stats)
	{
		VariableStatEntry *entry = dlist_container(VariableStatEntry, node,
												   iter.cur);

		dlist_delete(iter.cur);
		if (!entry->active)
			continue;

		if (entry->status)
		{
#ifdef PGPRO_EE
			hash_seq_term_all_levels(entry->status);
#else
			hash_seq_term(entry->status);
#endif
		}
		VariableStatEntry_clear_fctx(entry);
		VariableStatEntry_deactivate(entry);
	}

	dlist_init(&variables_stats);

	dlist_foreach_modify(iter, &packages_stats)
	{
		PackageStatEntry *entry = dlist_container(PackageStatEntry, node,
												  iter.cur);

		dlist_delete(iter.cur);
		if (!entry->active)
			continue;

		if (entry->status)
		{
#ifdef PGPRO_EE
			hash_seq_term_all_levels(entry->status);
#else
			hash_seq_term(entry->status);
#endif
		}
		PackageStatEntry_clear_fctx(entry);
		PackageStatEntry_deactivate(entry);
	}

	dlist_init(&packages_stats);
}

/*
 * Register callback function when module starts
 */
void
_PG_init(void)
{
	DefineCustomBoolVariable("pg_variables.convert_unknownoid",
							 "Use \'TEXT\' format for all values of \'UNKNOWNOID\', default is true.",
							 NULL,
						     &convert_unknownoid,
							 true,
							 PGC_USERSET,
							 0, /* FLAGS??? */
							 NULL,
							 NULL,
							 NULL);

#ifdef PGPRO_EE
	active_atx_level = getNestLevelATX();
	PgproRegisterXactCallback(pgvTransCallback, NULL, XACT_EVENT_KIND_VANILLA | XACT_EVENT_KIND_ATX);
#else
	RegisterXactCallback(pgvTransCallback, NULL);
#endif
	RegisterSubXactCallback(pgvSubTransCallback, NULL);
}

#if PG_VERSION_NUM < 150000
/*
 * Unregister callback function when module unloads
 */
void
_PG_fini(void)
{
	UnregisterXactCallback(pgvTransCallback, NULL);
	UnregisterSubXactCallback(pgvSubTransCallback, NULL);
}
#endif

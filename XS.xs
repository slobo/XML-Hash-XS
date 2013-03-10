#include "EXTERN.h"
#include "perl.h"
#define NO_XSLOCKS
#include "XSUB.h"
#include "ppport.h"

#include <libxml/parser.h>

#ifndef MUTABLE_PTR
#if defined(__GNUC__) && !defined(PERL_GCC_BRACE_GROUPS_FORBIDDEN)
#  define MUTABLE_PTR(p) ({ void *_p = (p); _p; })
#else
#  define MUTABLE_PTR(p) ((void *) (p))
#endif
#endif

#ifndef MUTABLE_SV
#define MUTABLE_SV(p)   ((SV *)MUTABLE_PTR(p))
#endif

#if __GNUC__ >= 3
# define expect(expr,value)         __builtin_expect ((expr), (value))
# define INLINE                     static inline
#else
# define expect(expr,value)         (expr)
# define INLINE                     static
#endif

#define expect_false(expr) expect ((expr) != 0, 0)
#define expect_true(expr)  expect ((expr) != 0, 1)

#define FLAG_SIMPLE                     1
#define FLAG_COMPLEX                    2
#define FLAG_CONTENT                    4
#define FLAG_ATTR_ONLY                  8

#define MAX_RECURSION_DEPTH             128

#define BUFFER_WRITE(str, len)          XMLHash_writer_write(ctx->writer, str, len)
#define BUFFER_WRITE_CONSTANT(str)      XMLHash_writer_write(ctx->writer, str, sizeof(str) - 1)
#define BUFFER_WRITE_STRING(str,len)    XMLHash_writer_write(ctx->writer, str, len)
#define BUFFER_WRITE_ESCAPE(str, len)   XMLHash_writer_escape_content(ctx->writer, str, len)
#define BUFFER_WRITE_ESCAPE_ATTR(str)   XMLHash_writer_escape_attr(ctx->writer, str)
#define BUFFER_WRITE_QUOTED(str)        XMLHash_writer_write_quoted_string(ctx->writer, str)

#ifndef FALSE
#define FALSE (0)
#endif

#ifndef TRUE
#define TRUE  (1)
#endif

#define CONV_DEF_OUTPUT    NULL
#define CONV_DEF_METHOD    "NATIVE"
#define CONV_DEF_ROOT      "root"
#define CONV_DEF_VERSION   "1.0"
#define CONV_DEF_ENCODING  "utf-8"
#define CONV_DEF_INDENT    0
#define CONV_DEF_CANONICAL FALSE
#define CONV_DEF_USE_ATTR  FALSE
#define CONV_DEF_CONTENT   ""
#define CONV_DEF_XML_DECL  TRUE

#define CONV_DEF_ATTR      "-"
#define CONV_DEF_TEXT      "#text"
#define CONV_DEF_TRIM      TRUE
#define CONV_DEF_CDATA     ""
#define CONV_DEF_COMM      ""

#define CONV_STR_PARAM_LEN 32

#define CONV_READ_PARAM_INIT                            \
    SV   *sv;                                           \
    char *str;
#define CONV_READ_STRING_PARAM($var, $name, $def_value) \
    if ( (sv = get_sv($name, 0)) != NULL ) {            \
        if ( SvOK(sv) ) {                               \
            str = (char *) SvPV_nolen(sv);              \
            strncpy($var, str, CONV_STR_PARAM_LEN);     \
        }                                               \
        else {                                          \
            $var[0] = '\0';                             \
        }                                               \
    }                                                   \
    else {                                              \
        strncpy($var, $def_value, CONV_STR_PARAM_LEN);  \
    }
#define CONV_READ_BOOL_PARAM($var, $name, $def_value)   \
    if ( (sv = get_sv($name, 0)) != NULL ) {            \
        if ( SvTRUE(sv) ) {                             \
            $var = TRUE;                                \
        }                                               \
        else {                                          \
            $var = FALSE;                               \
        }                                               \
    }                                                   \
    else {                                              \
        $var = $def_value;                              \
    }
#define CONV_READ_INT_PARAM($var, $name, $def_value)    \
    if ( (sv = get_sv($name, 0)) != NULL ) {            \
        $var = SvIV(sv);                                \
    }                                                   \
    else {                                              \
        $var = $def_value;                              \
    }
#define CONV_READ_REF_PARAM($var, $name, $def_value)    \
    if ( (sv = get_sv($name, 0)) != NULL ) {            \
        if ( SvOK(sv) && SvROK(sv) ) {                  \
            $var = sv;                                  \
        }                                               \
        else {                                          \
            $var = NULL;                                \
        }                                               \
    }                                                   \
    else {                                              \
        $var = $def_value;                              \
    }

typedef uintptr_t bool_t;

typedef enum {
    CONV_METHOD_NATIVE,
    CONV_METHOD_NATIVE_ATTR_MODE,
    CONV_METHOD_LX,
} convMethodType;

typedef int (*conv_write_callback_t)(void * context, const char * buf, int len);
typedef int (*conv_close_callback_t)(void * context);

typedef struct _conv_buffer_t conv_buffer_t;
struct _conv_buffer_t {
    char          *pos;
    char          *start;
    char          *end;
    conv_buffer_t *prev;
};

typedef struct _conv_encoder_t conv_encoder_t;
struct _conv_encoder_t {
};

typedef struct _conv_writer_t conv_writer_t;
struct _conv_writer_t {
    conv_write_callback_t *write_callback;
    conv_close_callback_t *close_callback;
    conv_encoder_t        *encoder;
    SV                    *perl_buf;
    char                  *buf;
    char                  *buf_pos;
    char                  *buf_end;
};

struct _conv_opts_t {
    convMethodType            method;

    /* native options */
    char               version[CONV_STR_PARAM_LEN];
    char               encoding[CONV_STR_PARAM_LEN];
    char               root[CONV_STR_PARAM_LEN];
    bool_t             xml_decl;
    bool_t             canonical;
    char               content[CONV_STR_PARAM_LEN];
    int                indent;
    void              *output;

    /* LX options */
    char               attr[CONV_STR_PARAM_LEN];
    int                attr_len;
    char               text[CONV_STR_PARAM_LEN];
    bool_t             trim;
    char               cdata[CONV_STR_PARAM_LEN];
    char               comm[CONV_STR_PARAM_LEN];
};
typedef struct _conv_opts_t conv_opts_t;

typedef enum {
    TAG_OPEN,
    TAG_CLOSE,
    TAG_EMPTY,
    TAG_START,
    TAG_END
} tagType;

typedef struct {
    char *key;
    void *value;
} hash_entity_t;

typedef struct _stash_entity_t stash_entity_t;
struct _stash_entity_t {
    void                   *data;
    struct _stash_entity_t *next;
};

typedef struct {
    conv_opts_t        opts;
    int                recursion_depth;
    int                indent_count;
    xmlOutputBufferPtr buf;
    stash_entity_t     stash;
    conv_writer_t     *writer;
} convert_ctx_t;

const char indent_string[60] = "                                                            ";

INLINE void XMLHash_write_item_no_attr(convert_ctx_t *ctx, char *name, SV *value);
INLINE int  XMLHash_write_item(convert_ctx_t *ctx, char *name, SV *value, int flag);
INLINE void XMLHash_write_hash(convert_ctx_t *ctx, char *name, SV *hash);
INLINE void XMLHash_write_hash_lx(convert_ctx_t *ctx, SV *hash, int flag);

void
XMLHash_writer_resize_buffer(conv_writer_t *writer, int add_size)
{
    int use  = writer->buf_pos - writer->buf;
    int size = writer->buf_end - writer->buf;
    if (add_size == 0 || add_size < size) {
        add_size = size;
    }

    SvCUR_set(writer->perl_buf, use);
    SvGROW(writer->perl_buf, size + add_size);
    writer->buf       = SvPVX(writer->perl_buf);
    writer->buf_pos   = writer->buf + use;
    writer->buf_end   = writer->buf + size + add_size;
}

conv_writer_t *
XMLHash_writer_create(int size)
{
    conv_writer_t *writer;

    writer = malloc(sizeof(conv_writer_t));
    if (writer == NULL) {
        croak("Memory allocation error");
    }
    memset(writer, 0, sizeof(conv_writer_t));

    writer->perl_buf = newSV(size);
    sv_setpv(writer->perl_buf, "");

    writer->buf      = writer->buf_pos = SvPVX(writer->perl_buf);
    writer->buf_end  = writer->buf + size;

    return writer;
}

INLINE void
XMLHash_writer_write(conv_writer_t *writer, const char *content, int len) {
    if (len > (writer->buf_end - writer->buf_pos -1)) {
        XMLHash_writer_resize_buffer(writer, len + 1);
    }

    if (len < 17) {
        while (len--) {
            *writer->buf_pos++ = *content++;
        }
    }
    else {
        memcpy(writer->buf_pos, content, len);
        writer->buf_pos += len;
    }
}

void
XMLHash_writer_write_quoted_string(conv_writer_t *writer, const char *content)
{
    char ch;
    const char *cur;
    int  len = 0;
    int  dq  = 0;
    int  sq  = 0;

    cur = content;
    while ((ch = *cur++) != '\0') {
        len++;
        if (ch == '"') {
            dq++;
        }
        else if (ch == '\'') {
            sq++;
        }
    }

    if (len == 0) return;

    len *= 6;

    if (len > (writer->buf_end - writer->buf_pos -1)) {
        XMLHash_writer_resize_buffer(writer, len + 1);
    }

    if (dq) {
        if (sq) {
            *writer->buf_pos++ = '"';
            while ((ch = *content++) != '\0') {
                if (ch == '"') {
                    *writer->buf_pos++ = '&';
                    *writer->buf_pos++ = 'q';
                    *writer->buf_pos++ = 'u';
                    *writer->buf_pos++ = 'o';
                    *writer->buf_pos++ = 't';
                    *writer->buf_pos++ = ';';
                }
                else {
                    *writer->buf_pos++ = ch;
                }
            }
            *writer->buf_pos++ = '"';
        }
        else {
            *writer->buf_pos++ = '\'';
            while ((ch = *content++) != '\0') {
                *writer->buf_pos++ = ch;
            }
            *writer->buf_pos++ = '\'';
        }
    }
    else {
        *writer->buf_pos++ = '"';
        while ((ch = *content++) != '\0') {
            *writer->buf_pos++ = ch;
        }
        *writer->buf_pos++ = '"';
    }
}

INLINE void
XMLHash_writer_escape_attr(conv_writer_t *writer, const char *content)
{
    char ch;
    int len = strlen(content) * 6;

    if (len > (writer->buf_end - writer->buf_pos -1)) {
        XMLHash_writer_resize_buffer(writer, len + 1);
    }

    while ((ch = *content++) != 0) {
        switch (ch) {
            case '\n':
                *writer->buf_pos++ = '&';
                *writer->buf_pos++ = '#';
                *writer->buf_pos++ = '1';
                *writer->buf_pos++ = '0';
                *writer->buf_pos++ = ';';
                break;
            case '\r':
                *writer->buf_pos++ = '&';
                *writer->buf_pos++ = '#';
                *writer->buf_pos++ = '1';
                *writer->buf_pos++ = '3';
                *writer->buf_pos++ = ';';
                break;
            case '\t':
                *writer->buf_pos++ = '&';
                *writer->buf_pos++ = '#';
                *writer->buf_pos++ = '9';
                *writer->buf_pos++ = ';';
                break;
            case '<':
                *writer->buf_pos++ = '&';
                *writer->buf_pos++ = 'l';
                *writer->buf_pos++ = 't';
                *writer->buf_pos++ = ';';
                break;
            case '>':
                *writer->buf_pos++ = '&';
                *writer->buf_pos++ = 'g';
                *writer->buf_pos++ = 't';
                *writer->buf_pos++ = ';';
                break;
            case '&':
                *writer->buf_pos++ = '&';
                *writer->buf_pos++ = 'a';
                *writer->buf_pos++ = 'm';
                *writer->buf_pos++ = 'p';
                *writer->buf_pos++ = ';';
                break;
            case '"':
                *writer->buf_pos++ = '&';
                *writer->buf_pos++ = 'q';
                *writer->buf_pos++ = 'u';
                *writer->buf_pos++ = 'o';
                *writer->buf_pos++ = 't';
                *writer->buf_pos++ = ';';
                break;
            default:
                *writer->buf_pos++ = ch;
        }
    }
}

INLINE void
XMLHash_writer_escape_content(conv_writer_t *writer, const char *content, int len)
{
    char ch;
    int max_len;

    if (len == -1) len = strlen(content);
    max_len = len * 5;

    if (max_len > (writer->buf_end - writer->buf_pos - 1)) {
        XMLHash_writer_resize_buffer(writer, max_len + 1);
    }

    while (len--) {
        ch = *content++;
        switch (ch) {
            case '\r':
                *writer->buf_pos++ = '&';
                *writer->buf_pos++ = '#';
                *writer->buf_pos++ = '1';
                *writer->buf_pos++ = '3';
                *writer->buf_pos++ = ';';
                break;
            case '<':
                *writer->buf_pos++ = '&';
                *writer->buf_pos++ = 'l';
                *writer->buf_pos++ = 't';
                *writer->buf_pos++ = ';';
                break;
            case '>':
                *writer->buf_pos++ = '&';
                *writer->buf_pos++ = 'g';
                *writer->buf_pos++ = 't';
                *writer->buf_pos++ = ';';
                break;
            case '&':
                *writer->buf_pos++ = '&';
                *writer->buf_pos++ = 'a';
                *writer->buf_pos++ = 'm';
                *writer->buf_pos++ = 'p';
                *writer->buf_pos++ = ';';
                break;
            default:
                *writer->buf_pos++ = ch;
        }
    }
}

SV *
XMLHash_writer_flush(conv_writer_t *writer)
{
    *writer->buf_pos = '\0';
    SvCUR_set(writer->perl_buf, writer->buf_pos - writer->buf);
    return writer->perl_buf;
}

void
XMLHash_writer_destroy(conv_writer_t *writer)
{
    free(writer);
}

static int
cmpstringp(const void *p1, const void *p2)
{
    hash_entity_t *e1, *e2;
    e1 = (hash_entity_t *) p1;
    e2 = (hash_entity_t *) p2;
    return strcmp(e1->key, e2->key);
}

INLINE char *
XMLHash_trim_string(char *s, int *len)
{
    char *cur, *end, ch;
    int first = 1;

    end = cur = s;
    while ((ch = *cur++) != '\0') {
        if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
            if (first) {
                s = end = cur;
            }
        }
        else {
            if (first) {
                first--;
            }
            end = cur;
        }
    }

    *len = end - s;

    return s;
}

int
XMLHash_write_handler(void *fp, char *buffer, int len)
{
    if ( buffer != NULL && len > 0)
        PerlIO_write(fp, buffer, len);

    return len;
}

int
XMLHash_write_tied_handler(void *obj, char *buffer, int len)
{
    if ( buffer != NULL && len > 0) {
        dSP;

        ENTER;
        SAVETMPS;

        PUSHMARK(SP);
        EXTEND(SP, 2);
        PUSHs((SV *)obj);
        PUSHs(sv_2mortal(newSVpv(buffer, len)));
        PUTBACK;

        call_method("PRINT", G_SCALAR);

        FREETMPS;
        LEAVE;
    }

    return len;
}

int
XMLHash_close_handler(void *fh)
{
    return 1;
}

INLINE void
XMLHash_write_tag(convert_ctx_t *ctx, tagType type, char *name, int indent, int lf)
{
    int indent_len;

    if (name == NULL) return;

    if (indent) {
        indent_len = ctx->indent_count * indent;
        if (indent_len > sizeof(indent_string))
            indent_len = sizeof(indent_string);

        BUFFER_WRITE(indent_string, indent_len);
    }

    if (type == TAG_CLOSE) {
        BUFFER_WRITE_CONSTANT("</");
    }
    else {
        BUFFER_WRITE_CONSTANT("<");
    }

    if (name[0] >= '1' && name[0] <= '9')
        BUFFER_WRITE_CONSTANT("_");

    BUFFER_WRITE_STRING(name, strlen(name));

    if (type == TAG_EMPTY) {
        BUFFER_WRITE_CONSTANT("/>");
    }
    else if (type == TAG_CLOSE || type == TAG_OPEN) {
        BUFFER_WRITE_CONSTANT(">");
    }

    if (lf)
        BUFFER_WRITE_CONSTANT("\n");
}

INLINE void
XMLHash_write_content(convert_ctx_t *ctx, char *value, int indent, int lf)
{
    int indent_len, str_len;

    if (indent) {
        indent_len = ctx->indent_count * indent;
        if (indent_len > sizeof(indent_string))
            indent_len = sizeof(indent_string);

        BUFFER_WRITE(indent_string, indent_len);
    }

    if (ctx->opts.trim) {
        value = XMLHash_trim_string(value, &str_len);
        BUFFER_WRITE_ESCAPE(value, str_len);
    }
    else {
        BUFFER_WRITE_ESCAPE(value, -1);
    }

    if (lf)
        BUFFER_WRITE_CONSTANT("\n");
}

INLINE void
XMLHash_write_cdata(convert_ctx_t *ctx, char *value, int indent, int lf)
{
    int indent_len, str_len;

    if (indent) {
        indent_len = ctx->indent_count * indent;
        if (indent_len > sizeof(indent_string))
            indent_len = sizeof(indent_string);

        BUFFER_WRITE(indent_string, indent_len);
    }

    BUFFER_WRITE_CONSTANT("<![CDATA[");
    if (ctx->opts.trim) {
        value = XMLHash_trim_string(value, &str_len);
        BUFFER_WRITE_STRING(value, str_len);
    }
    else {
        BUFFER_WRITE_STRING(value, strlen(value));
    }
    BUFFER_WRITE_CONSTANT("]]>");

    if (lf)
        BUFFER_WRITE_CONSTANT("\n");
}

void
XMLHash_write_comment(convert_ctx_t *ctx, char *value, int indent, int lf)
{
    int indent_len, str_len;

    if (indent) {
        indent_len = ctx->indent_count * indent;
        if (indent_len > sizeof(indent_string))
            indent_len = sizeof(indent_string);

        BUFFER_WRITE(indent_string, indent_len);
    }

    BUFFER_WRITE_CONSTANT("<!--");
    if (ctx->opts.trim) {
        value = XMLHash_trim_string(value, &str_len);
        BUFFER_WRITE_STRING(value, str_len);
    }
    else {
        BUFFER_WRITE_STRING(value, strlen(value));
    }
    BUFFER_WRITE_CONSTANT("-->");

    if (lf)
        BUFFER_WRITE_CONSTANT("\n");
}

INLINE void
XMLHash_write_attribute_element(convert_ctx_t *ctx, char *name, xmlChar *value)
{
    if (name == NULL) return;

    BUFFER_WRITE_CONSTANT(" ");
    BUFFER_WRITE_STRING(name, strlen(name));
    BUFFER_WRITE_CONSTANT("=\"");
    BUFFER_WRITE_ESCAPE_ATTR(value);
    BUFFER_WRITE_CONSTANT("\"");
}

void
XMLHash_stash_push(stash_entity_t *stash, void *data)
{
    stash_entity_t *ent;
    ent = malloc(sizeof(stash_entity_t));
    if (ent == NULL)
        croak("Malloc error");

    ent->data   = data;
    ent->next   = stash->next;
    stash->next = ent;
}

void
XMLHash_stash_clean(stash_entity_t *stash)
{
    stash_entity_t *ent;

    while (stash->next != NULL) {
        ent = stash->next;
        SvREFCNT_dec((SV *)ent->data);
        stash->next = ent->next;
        free(ent);
    }
}

INLINE void
XMLHash_resolve_value(convert_ctx_t *ctx, SV **value, SV **value_ref, int *raw)
{
    int count;
    svtype svt;
    SV *sv;

    *raw = 0;

    while ( *value && SvROK(*value) ) {
        if (++ctx->recursion_depth > MAX_RECURSION_DEPTH)
            croak("Maximum recursion depth exceeded");

        *value_ref = *value;
        *value     = SvRV(*value);
        sv         = *value;

        if (expect_false( SvOBJECT(sv) )) {
            /* object */
            GV *to_string = gv_fetchmethod_autoload (SvSTASH (sv), "toString", 0);
            if (to_string) {
                dSP;

                ENTER; SAVETMPS; PUSHMARK (SP);
                XPUSHs (sv_bless (sv_2mortal (newRV_inc (sv)), SvSTASH (sv)));

                // calling with G_SCALAR ensures that we always get a 1 return value
                PUTBACK;
                call_sv ((SV *)GvCV (to_string), G_SCALAR);
                SPAGAIN;

                // catch this surprisingly common error
                if (SvROK (TOPs) && SvRV (TOPs) == sv)
                    croak("%s::toString method returned same object as was passed instead of a new one", HvNAME (SvSTASH (sv)));

                *value = POPs;
                PUTBACK;

                SvREFCNT_inc(*value);

                XMLHash_stash_push(&ctx->stash, *value);

                FREETMPS; LEAVE;

                *raw = 1;

                continue;
            }
        }
        else if(SvTYPE(*value) == SVt_PVCV) {
            /* code ref */
            *raw = 0;

            dSP;

            ENTER;
            SAVETMPS;
            count = call_sv(*value, G_SCALAR|G_NOARGS);

            SPAGAIN;

            if (count == 1) {
                *value = POPs;

                SvREFCNT_inc(*value);

                XMLHash_stash_push(&ctx->stash, *value);

                PUTBACK;

                FREETMPS;
                LEAVE;

                continue;
            }
            else {
                *value = NULL;
            }
        }
    }
}

INLINE void
XMLHash_write_hash_no_attr(convert_ctx_t *ctx, char *name, SV *hash)
{
    SV   *value;
    HV   *hv;
    char *key;
    I32   keylen;
    int   i, len;

    if (!SvROK(hash)) {
        warn("parameter is not reference\n");
        return;
    }

    hv  = (HV *) SvRV(hash);
    len = HvUSEDKEYS(hv);

    if (len == 0) {
        XMLHash_write_tag(ctx, TAG_EMPTY, name, ctx->opts.indent, ctx->opts.indent);
        return;
    }

    XMLHash_write_tag(ctx, TAG_OPEN, name, ctx->opts.indent, ctx->opts.indent);

    ctx->indent_count++;

    hv_iterinit(hv);

    if (ctx->opts.canonical) {
        hash_entity_t a[len];

        i = 0;
        while ((value = hv_iternextsv(hv, &key, &keylen))) {
            a[i].value = value;
            a[i].key   = key;
            i++;
        }
        len = i;

        qsort(&a, len, sizeof(hash_entity_t), cmpstringp);

        for (i = 0; i < len; i++) {
            key   = a[i].key;
            value = a[i].value;
            XMLHash_write_item_no_attr(ctx, key, value);
        }
    }
    else {
        while ((value = hv_iternextsv(hv, &key, &keylen))) {
            XMLHash_write_item_no_attr(ctx, key, value);
        }
    }

    ctx->indent_count--;

    XMLHash_write_tag(ctx, TAG_CLOSE, name, ctx->opts.indent, ctx->opts.indent);
}

INLINE void
XMLHash_write_item_no_attr(convert_ctx_t *ctx, char *name, SV *value)
{
    I32        i, len;
    int        count, raw;
    SV        *value_ref;
    char      *str;
    STRLEN     str_len;

    XMLHash_resolve_value(ctx, &value, &value_ref, &raw);

    switch (SvTYPE(value)) {
        case SVt_NULL:
            XMLHash_write_tag(ctx, TAG_EMPTY, name, ctx->opts.indent, ctx->opts.indent);
            break;
        case SVt_IV:
        case SVt_PVIV:
        case SVt_PVNV:
        case SVt_NV:
        case SVt_PV:
            /* integer, double, scalar */
            XMLHash_write_tag(ctx, TAG_OPEN, name, ctx->opts.indent, 0);
            str = SvPV(value, str_len);
            if (raw) {
                BUFFER_WRITE_STRING(str, str_len);
            }
            else {
                BUFFER_WRITE_ESCAPE(str, str_len);
            }
            XMLHash_write_tag(ctx, TAG_CLOSE, name, 0, ctx->opts.indent);
            break;
        case SVt_PVAV:
            /* array */
            len = av_len((AV *) value);
            for (i = 0; i <= len; i++) {
                XMLHash_write_item_no_attr(ctx, name, *av_fetch((AV *) value, i, 0));
            }
            break;
        case SVt_PVHV:
            /* hash */
            XMLHash_write_hash_no_attr(ctx, name, value_ref);
            break;
        case SVt_PVMG:
            /* blessed */
            if (SvOK(value)) {
                str = SvPV(value, str_len);
                XMLHash_write_tag(ctx, TAG_OPEN, name, ctx->opts.indent, 0);
                if (raw) {
                    BUFFER_WRITE_STRING(str, str_len);
                }
                else {
                    BUFFER_WRITE_ESCAPE(str, str_len);
                }
                XMLHash_write_tag(ctx, TAG_CLOSE, name, 0, ctx->opts.indent);
                break;
            }
        default:
            XMLHash_write_tag(ctx, TAG_EMPTY, name, ctx->opts.indent, ctx->opts.indent);
    }

    ctx->recursion_depth--;
}

INLINE int
XMLHash_write_item(convert_ctx_t *ctx, char *name, SV *value, int flag)
{
    int        count = 0, raw = 0;
    I32        len, i;
    SV        *value_ref;

    if (ctx->opts.content[0] != '\0' && strcmp(name, ctx->opts.content) == 0) {
        flag = flag | FLAG_CONTENT;
    }

    XMLHash_resolve_value(ctx, &value, &value_ref, &raw);

    switch (SvTYPE(value)) {
        case SVt_NULL:
            if (flag & FLAG_SIMPLE && flag & FLAG_COMPLEX) {
                XMLHash_write_tag(ctx, TAG_EMPTY, name, ctx->opts.indent, ctx->opts.indent);
            }
            else if (flag & FLAG_SIMPLE && !(flag & FLAG_CONTENT)) {
                XMLHash_write_attribute_element(ctx, name, NULL);
                count++;
            }
            break;
        case SVt_IV:
        case SVt_PVIV:
        case SVt_PVNV:
        case SVt_NV:
        case SVt_PV:
            /* integer, double, scalar */
            if (flag & FLAG_SIMPLE && flag & FLAG_COMPLEX) {
                ctx->indent_count++;
                XMLHash_write_tag(ctx, TAG_OPEN, name, ctx->opts.indent, 0);
                BUFFER_WRITE_ESCAPE(SvPV_nolen(value), -1);
                XMLHash_write_tag(ctx, TAG_CLOSE, name, 0, ctx->opts.indent);
                ctx->indent_count--;
            }
            else if (flag & FLAG_COMPLEX && flag & FLAG_CONTENT) {
                ctx->indent_count++;
                XMLHash_write_content(ctx, SvPV_nolen(value), ctx->opts.indent, ctx->opts.indent);
                ctx->indent_count--;
            }
            else if (flag & FLAG_SIMPLE && !(flag & FLAG_CONTENT)) {
                XMLHash_write_attribute_element(ctx, name, (xmlChar *) SvPV_nolen(value));
                count++;
            }
            break;
        case SVt_PVAV:
            /* array */
            if (flag & FLAG_COMPLEX) {
                len = av_len((AV *) value);
                for (i = 0; i <= len; i++) {
                    XMLHash_write_item(ctx, name, *av_fetch((AV *) value, i, 0), FLAG_SIMPLE | FLAG_COMPLEX);
                }
                count++;
            }
            break;
        case SVt_PVHV:
            /* hash */
            if (flag & FLAG_COMPLEX) {
                ctx->indent_count++;
                XMLHash_write_hash(ctx, name, value_ref);
                ctx->indent_count--;
                count++;
            }
            break;
        case SVt_PVMG:
            /* blessed */
            if (SvOK(value)) {
                if (flag & FLAG_SIMPLE && flag & FLAG_COMPLEX) {
                    ctx->indent_count++;
                    XMLHash_write_tag(ctx, TAG_OPEN, name, ctx->opts.indent, 0);
                    BUFFER_WRITE_ESCAPE(SvPV_nolen(value), -1);
                    XMLHash_write_tag(ctx, TAG_CLOSE, name, 0, ctx->opts.indent);
                    ctx->indent_count--;
                }
                else if (flag & FLAG_COMPLEX && flag & FLAG_CONTENT) {
                    ctx->indent_count++;
                    XMLHash_write_content(ctx, SvPV_nolen(value), ctx->opts.indent, ctx->opts.indent);
                    ctx->indent_count--;
                }
                else if (flag & FLAG_SIMPLE && !(flag & FLAG_CONTENT)) {
                    XMLHash_write_attribute_element(ctx, name, (xmlChar *) SvPV_nolen(value));
                    count++;
                }
                break;
            }
        default:
            if (flag & FLAG_SIMPLE && !(flag & FLAG_CONTENT)) {
                XMLHash_write_attribute_element(ctx, name, NULL);
                count++;
            }
    }

    ctx->recursion_depth--;

    return count;
}

INLINE void
XMLHash_write_hash(convert_ctx_t *ctx, char *name, SV *hash)
{
    SV   *value;
    HV   *hv;
    char *key;
    I32   keylen;
    int   i, done, len;

    if (!SvROK(hash)) {
        warn("parameter is not reference\n");
        return;
    }

    hv  = (HV *) SvRV(hash);
    len = HvUSEDKEYS(hv);

    if (len == 0) {
        XMLHash_write_tag(ctx, TAG_EMPTY, name, ctx->opts.indent, ctx->opts.indent);
        return;
    }

    XMLHash_write_tag(ctx, TAG_START, name, ctx->opts.indent, 0);

    hv_iterinit(hv);

    if (ctx->opts.canonical) {
        hash_entity_t a[len];

        i = 0;
        while ((value = hv_iternextsv(hv, &key, &keylen))) {
            a[i].value = value;
            a[i].key   = key;
            i++;
        }
        len = i;

        qsort(&a, len, sizeof(hash_entity_t), cmpstringp);

        done = 0;
        for (i = 0; i < len; i++) {
            key   = a[i].key;
            value = a[i].value;
            done += XMLHash_write_item(ctx, key, value, FLAG_SIMPLE);
        }

        if (done == len) {
            if (ctx->opts.indent) {
                BUFFER_WRITE_CONSTANT("/>\n");
            }
            else {
                BUFFER_WRITE_CONSTANT("/>");
            }
        }
        else {
            if (ctx->opts.indent) {
                BUFFER_WRITE_CONSTANT(">\n");
            }
            else {
                BUFFER_WRITE_CONSTANT(">");
            }

            for (i = 0; i < len; i++) {
                key   = a[i].key;
                value = a[i].value;
                XMLHash_write_item(ctx, key, value, FLAG_COMPLEX);
            }

            XMLHash_write_tag(ctx, TAG_CLOSE, name, ctx->opts.indent, ctx->opts.indent);
        }
    }
    else {
        done = 0;
        len  = 0;

        while ((value = hv_iternextsv(hv, &key, &keylen))) {
            done += XMLHash_write_item(ctx, key, value, FLAG_SIMPLE);
            len++;
        }

        if (done == len) {
            if (ctx->opts.indent) {
                BUFFER_WRITE_CONSTANT("/>\n");
            }
            else {
                BUFFER_WRITE_CONSTANT("/>");
            }
        }
        else {
            if (ctx->opts.indent) {
                BUFFER_WRITE_CONSTANT(">\n");
            }
            else {
                BUFFER_WRITE_CONSTANT(">");
            }

            while ((value = hv_iternextsv(hv, &key, &keylen))) {
                XMLHash_write_item(ctx, key, value, FLAG_COMPLEX);
            }


            XMLHash_write_tag(ctx, TAG_CLOSE, name, ctx->opts.indent, ctx->opts.indent);
        }
    }
}

void
XMLHash_write_hash_lx(convert_ctx_t *ctx, SV *value, int flag)
{
    SV   *value_ref, *hash_value, *hash_value_ref;
    HV   *hv;
    char *key;
    I32   keylen;
    int   len, i, raw = 0;

    XMLHash_resolve_value(ctx, &value, &value_ref, &raw);

    switch (SvTYPE(value)) {
        case SVt_NULL:
            XMLHash_write_content(ctx, "", ctx->opts.indent, ctx->opts.indent);
            break;
        case SVt_IV:
        case SVt_PVIV:
        case SVt_PVNV:
        case SVt_NV:
        case SVt_PV:
            if (flag & FLAG_ATTR_ONLY) break;
            XMLHash_write_content(ctx, SvPV_nolen(value), ctx->opts.indent, ctx->opts.indent);
            break;
        case SVt_PVAV:
            len = av_len((AV *) value);
            for (i = 0; i <= len; i++) {
                XMLHash_write_hash_lx(ctx, *av_fetch((AV *) value, i, 0), flag);
            }
            break;
        case SVt_PVHV:
            hv  = (HV *) value;
            len = HvUSEDKEYS(hv);
            hv_iterinit(hv);

            while ((hash_value = hv_iternextsv(hv, &key, &keylen))) {
                if (ctx->opts.cdata[0] != '\0' && strcmp(key, ctx->opts.cdata) == 0) {
                    if (flag & FLAG_ATTR_ONLY) continue;
                    XMLHash_resolve_value(ctx, &hash_value, &hash_value_ref, &raw);
                    switch (SvTYPE(hash_value)) {
                        case SVt_NULL:
                            break;
                        case SVt_IV:
                        case SVt_PVIV:
                        case SVt_PVNV:
                        case SVt_NV:
                        case SVt_PV:
                            XMLHash_write_cdata(ctx, SvPV_nolen(hash_value), ctx->opts.indent, ctx->opts.indent);
                            break;
                        case SVt_PVAV:
                        case SVt_PVHV:
                            break;
                        case SVt_PVMG:
                            if (SvOK(value)) {
                                XMLHash_write_cdata(ctx, SvPV_nolen(hash_value), ctx->opts.indent, ctx->opts.indent);
                                break;
                            }
                        default:
                            XMLHash_write_cdata(ctx, SvPV_nolen(hash_value), ctx->opts.indent, ctx->opts.indent);
                    }
                }
                else if (ctx->opts.text[0] != '\0' && strcmp(key, ctx->opts.text) == 0) {
                    if (flag & FLAG_ATTR_ONLY) continue;
                    XMLHash_resolve_value(ctx, &hash_value, &hash_value_ref, &raw);
                    switch (SvTYPE(hash_value)) {
                        case SVt_NULL:
                            XMLHash_write_content(ctx, "", ctx->opts.indent, ctx->opts.indent);
                            break;
                        case SVt_IV:
                        case SVt_PVIV:
                        case SVt_PVNV:
                        case SVt_NV:
                        case SVt_PV:
                            XMLHash_write_content(ctx, SvPV_nolen(hash_value), ctx->opts.indent, ctx->opts.indent);
                            break;
                        case SVt_PVAV:
                        case SVt_PVHV:
                            break;
                        case SVt_PVMG:
                            if (SvOK(value)) {
                                XMLHash_write_content(ctx, SvPV_nolen(hash_value), ctx->opts.indent, ctx->opts.indent);
                                break;
                            }
                        default:
                            XMLHash_write_content(ctx, SvPV_nolen(hash_value), ctx->opts.indent, ctx->opts.indent);
                    }
                }
                else if (ctx->opts.comm[0] != '\0' && strcmp(key, ctx->opts.comm) == 0) {
                    if (flag & FLAG_ATTR_ONLY) continue;
                    XMLHash_resolve_value(ctx, &hash_value, &hash_value_ref, &raw);
                    switch (SvTYPE(hash_value)) {
                        case SVt_NULL:
                            XMLHash_write_comment(ctx, "", ctx->opts.indent, ctx->opts.indent);
                            break;
                        case SVt_IV:
                        case SVt_PVIV:
                        case SVt_PVNV:
                        case SVt_NV:
                        case SVt_PV:
                            XMLHash_write_comment(ctx, SvPV_nolen(hash_value), ctx->opts.indent, ctx->opts.indent);
                            break;
                        case SVt_PVAV:
                        case SVt_PVHV:
                            break;
                        case SVt_PVMG:
                            if (SvOK(value)) {
                                XMLHash_write_comment(ctx, SvPV_nolen(hash_value), ctx->opts.indent, ctx->opts.indent);
                                break;
                            }
                        default:
                            XMLHash_write_comment(ctx, SvPV_nolen(hash_value), ctx->opts.indent, ctx->opts.indent);
                    }
                }
                else if (ctx->opts.attr[0] != '\0') {
                    if (strncmp(key, ctx->opts.attr, ctx->opts.attr_len) == 0) {
                        if (!(flag & FLAG_ATTR_ONLY)) continue;
                        key += ctx->opts.attr_len;
                        XMLHash_resolve_value(ctx, &hash_value, &hash_value_ref, &raw);
                        switch (SvTYPE(hash_value)) {
                            case SVt_NULL:
                                XMLHash_write_attribute_element(ctx, key, (xmlChar *) "");
                                break;
                            case SVt_IV:
                            case SVt_PVIV:
                            case SVt_PVNV:
                            case SVt_NV:
                            case SVt_PV:
                                XMLHash_write_attribute_element(ctx, key, (xmlChar *) SvPV_nolen(hash_value));
                                break;
                            case SVt_PVAV:
                            case SVt_PVHV:
                                break;
                            case SVt_PVMG:
                                if (SvOK(value)) {
                                    XMLHash_write_attribute_element(ctx, key, (xmlChar *) SvPV_nolen(hash_value));
                                    break;
                                }
                            default:
                                XMLHash_write_attribute_element(ctx, key, (xmlChar *) SvPV_nolen(hash_value));
                        }
                    }
                    else {
                        if (flag & FLAG_ATTR_ONLY) continue;
                        if (SvTYPE(hash_value) == SVt_NULL) {
                            XMLHash_write_tag(ctx, TAG_EMPTY, key, ctx->opts.indent, ctx->opts.indent);
                        }
                        else {
                            XMLHash_write_tag(ctx, TAG_START, key, ctx->opts.indent, 0);
                            XMLHash_write_hash_lx(ctx, hash_value, FLAG_ATTR_ONLY);
                            if (ctx->opts.indent) {
                                BUFFER_WRITE_CONSTANT(">\n");
                            }
                            else {
                                BUFFER_WRITE_CONSTANT(">");
                            }
                            ctx->indent_count++;
                            XMLHash_write_hash_lx(ctx, hash_value, 0);
                            ctx->indent_count--;
                            XMLHash_write_tag(ctx, TAG_CLOSE, key, ctx->opts.indent, ctx->opts.indent);
                        }
                    }
                }
                else {
                    if (SvTYPE(hash_value) == SVt_NULL) {
                        XMLHash_write_tag(ctx, TAG_EMPTY, key, ctx->opts.indent, ctx->opts.indent);
                    }
                    else {
                        XMLHash_write_tag(ctx, TAG_OPEN, key, ctx->opts.indent, ctx->opts.indent);
                        ctx->indent_count++;
                        XMLHash_write_hash_lx(ctx, hash_value, 0);
                        ctx->indent_count--;
                        XMLHash_write_tag(ctx, TAG_CLOSE, key, ctx->opts.indent, ctx->opts.indent);
                    }
                }
            }

            break;
        case SVt_PVMG:
            /* blessed */
            if (flag & FLAG_ATTR_ONLY) break;
            if (SvOK(value)) {
                XMLHash_write_content(ctx, SvPV_nolen(value), ctx->opts.indent, ctx->opts.indent);
                break;
            }
        default:
            if (flag & FLAG_ATTR_ONLY) break;
            XMLHash_write_content(ctx, SvPV_nolen(value), ctx->opts.indent, ctx->opts.indent);
    }

    ctx->recursion_depth--;
}

void
XMLHash_conv_destroy(conv_opts_t *conv_opts)
{
    if (conv_opts != NULL) {
        free(conv_opts);
    }
}

bool_t
XMLHash_conv_init_options(conv_opts_t *opts)
{
    char   method[CONV_STR_PARAM_LEN];
    bool_t use_attr;

    CONV_READ_PARAM_INIT

    /* native options */
    CONV_READ_STRING_PARAM(opts->root,      "XML::Hash::XS::root",      CONV_DEF_ROOT);
    CONV_READ_STRING_PARAM(opts->version,   "XML::Hash::XS::version",   CONV_DEF_VERSION);
    CONV_READ_STRING_PARAM(opts->encoding,  "XML::Hash::XS::encoding",  CONV_DEF_ENCODING);
    CONV_READ_INT_PARAM   (opts->indent,    "XML::Hash::XS::indent",    CONV_DEF_INDENT);
    CONV_READ_BOOL_PARAM  (opts->canonical, "XML::Hash::XS::canonical", CONV_DEF_CANONICAL);
    CONV_READ_STRING_PARAM(opts->content,   "XML::Hash::XS::content",   CONV_DEF_CONTENT);
    CONV_READ_BOOL_PARAM  (opts->xml_decl,  "XML::Hash::XS::xml_decl",  CONV_DEF_XML_DECL);
    CONV_READ_BOOL_PARAM  (use_attr,        "XML::Hash::XS::use_attr",  CONV_DEF_USE_ATTR);

    /* XML::Hash::LX options */
    CONV_READ_STRING_PARAM(opts->attr,      "XML::Hash::XS::attr",      CONV_DEF_ATTR);
    opts->attr_len = strlen(opts->attr);
    CONV_READ_STRING_PARAM(opts->text,      "XML::Hash::XS::text",      CONV_DEF_TEXT);
    CONV_READ_BOOL_PARAM  (opts->trim,      "XML::Hash::XS::trim",      CONV_DEF_TRIM);
    CONV_READ_STRING_PARAM(opts->cdata,     "XML::Hash::XS::cdata",     CONV_DEF_CDATA);
    CONV_READ_STRING_PARAM(opts->comm,      "XML::Hash::XS::comm",      CONV_DEF_COMM);

    /* method */
    CONV_READ_STRING_PARAM(method,          "XML::Hash::XS::method",    CONV_DEF_METHOD);
    if (strcmp(method, "LX") == 0) {
        opts->method = CONV_METHOD_LX;
    }
    else if (use_attr) {
        opts->method = CONV_METHOD_NATIVE_ATTR_MODE;
    }
    else {
        opts->method = CONV_METHOD_NATIVE;
    }

    /* output, NULL - to string */
    CONV_READ_REF_PARAM   (opts->output,    "XML::Hash::XS::output",    CONV_DEF_OUTPUT);

    return TRUE;
}

conv_opts_t *
XMLHash_conv_create(void)
{
    conv_opts_t *conv_opts;

    if ((conv_opts = malloc(sizeof(conv_opts_t))) == NULL) {
        return NULL;
    }
    memset(conv_opts, 0, sizeof(conv_opts_t));

    if (! XMLHash_conv_init_options(conv_opts)) {
        XMLHash_conv_destroy(conv_opts);
        return NULL;
    }

    return conv_opts;
}

void
XMLHash_conv_assign_string_param(char param[], SV *value)
{
    char *str;

    if ( SvOK(value) ) {
        str = (char *) SvPV_nolen(value);
        strncpy(param, str, CONV_STR_PARAM_LEN);
    }
    else {
        *param = 0;
    }
}

void
XMLHash_conv_assign_int_param(char *name, int *param, SV *value)
{
    if ( !SvOK(value) ) {
        croak("Parameter '%s' is undefined", name);
    }
    *param = SvIV(value);
}

void
XMLHash_conv_assign_bool_param(bool_t *param, SV *value)
{
    if ( SvTRUE(value) )
        *param = TRUE;
    else
        *param = FALSE;
}

void
XMLHash_conv_parse_param(conv_opts_t *opts, int first, I32 ax, I32 items)
{
    int      i;
    char    *p, *cv;
    SV      *v;
    bool_t   use_attr = -1;

    if (first >= items) return;

    if ((items - first) % 2 != 0) {
        croak("Odd number of parameters in new()");
    }

    for (i = first; i < items; i = i + 2) {
        if (!SvOK(ST(i))) {
            croak("Parameter name is undefined");
        }

        p = (char *) SvPV(ST(i), PL_na);
        v = ST(i + 1);

        if (strcmp(p, "method") == 0) {
            if (!SvOK(v)) {
                croak("Parameter '%s' is undefined", p);
            }
            cv = SvPV_nolen(v);
            if (strcmp(cv, "NATIVE") == 0) {
                opts->method = CONV_METHOD_NATIVE;
            }
            else if (strcmp(cv, "LX") == 0) {
                opts->method = CONV_METHOD_LX;
            }
            else {
                croak("Invalid parameter value for '%s': %s", p, cv);
            }
        }
        else if (strcmp(p, "root") == 0) {
            XMLHash_conv_assign_string_param(opts->root, v);
        }
        else if (strcmp(p, "version") == 0) {
            XMLHash_conv_assign_string_param(opts->version, v);
        }
        else if (strcmp(p, "encoding") == 0) {
            XMLHash_conv_assign_string_param(opts->encoding, v);
        }
        else if (strcmp(p, "content") == 0) {
            XMLHash_conv_assign_string_param(opts->content, v);
        }
        else if (strcmp(p, "xml_decl") == 0) {
            XMLHash_conv_assign_bool_param(&opts->xml_decl, v);
        }
        else if (strcmp(p, "use_attr") == 0) {
            XMLHash_conv_assign_bool_param(&use_attr, v);
        }
        else if (strcmp(p, "canonical") == 0) {
            XMLHash_conv_assign_bool_param(&opts->canonical, v);
        }
        else if (strcmp(p, "indent") == 0) {
            XMLHash_conv_assign_int_param(p, &opts->indent, v);
        }
        else if (strcmp(p, "attr") == 0) {
            XMLHash_conv_assign_string_param(opts->attr, v);
            if (opts->attr[0] == '\0') {
                opts->attr_len = 0;
            }
            else {
                opts->attr_len = strlen(opts->attr);
            }
        }
        else if (strcmp(p, "trim") == 0) {
            XMLHash_conv_assign_bool_param(&opts->trim, v);
        }
        else if (strcmp(p, "text") == 0) {
            XMLHash_conv_assign_string_param(opts->text, v);
        }
        else if (strcmp(p, "cdata") == 0) {
            XMLHash_conv_assign_string_param(opts->cdata, v);
        }
        else if (strcmp(p, "comm") == 0) {
            XMLHash_conv_assign_string_param(opts->comm, v);
        }
        else if (strcmp(p, "output") == 0) {
            if ( SvOK(v) && SvROK(v) ) {
                opts->output = SvRV(v);
            }
            else {
                opts->output = NULL;
            }
        }
        else {
            croak("Invalid parameter '%s'", p);
        }
    }

    if (use_attr != -1 && (opts->method == CONV_METHOD_NATIVE || opts->method == CONV_METHOD_NATIVE_ATTR_MODE)) {
        if (use_attr == TRUE) {
            opts->method = CONV_METHOD_NATIVE_ATTR_MODE;
        }
        else {
            opts->method = CONV_METHOD_NATIVE;
        }
    }
}

void
__XMLHash_conv_create_buffer(convert_ctx_t *ctx)
{
    xmlCharEncodingHandlerPtr encoding_handler;

    encoding_handler = xmlFindCharEncodingHandler(ctx->opts.encoding);
    if ( encoding_handler == NULL )
        croak("Unknown encoding");

    if (ctx->opts.output == NULL) {
        /* output to string */
        ctx->buf = xmlAllocOutputBuffer(encoding_handler);
        ctx->writer = XMLHash_writer_create(16384);
    }
    else {
        MAGIC  *mg;
        PerlIO *fp;
        SV     *obj;
        GV     *gv = (GV *) ctx->opts.output;
        IO     *io = GvIO(gv);

        xmlRegisterDefaultOutputCallbacks();

        if (io && (mg = SvTIED_mg((SV *)io, PERL_MAGIC_tiedscalar))) {
            /* tied handle */
            obj = SvTIED_obj(MUTABLE_SV(io), mg);

            ctx->buf = xmlOutputBufferCreateIO(
                (xmlOutputWriteCallback) &XMLHash_write_tied_handler,
                (xmlOutputCloseCallback) &XMLHash_close_handler,
                obj, encoding_handler
            );
        }
        else {
            /* simple handle */
            fp = IoOFP(io);

            ctx->buf = xmlOutputBufferCreateIO(
                (xmlOutputWriteCallback) &XMLHash_write_handler,
                (xmlOutputCloseCallback) &XMLHash_close_handler,
                fp, encoding_handler
            );
        }
    }

    if (ctx->buf == NULL) {
        croak("Buffer allocation error");
    }
}

void
__XMLHash_conv_destroy_buffer(convert_ctx_t *ctx, xmlChar **result, int *len)
{
    if (ctx->buf == NULL) return;

    if (ctx->opts.output == NULL) {
        xmlOutputBufferFlush(ctx->buf);

        if (result != NULL) {

            if (ctx->buf->conv != NULL) {
#ifdef LIBXML2_NEW_BUFFER
                *len    = xmlBufUse(ctx->buf->conv);
                *result = xmlStrndup(xmlBufContent(ctx->buf->conv), *len);
#else
                *len    = ctx->buf->conv->use;
                *result = xmlStrndup(ctx->buf->conv->content, *len);
#endif
            }
            else {
#ifdef LIBXML2_NEW_BUFFER
                *len    = xmlOutputBufferGetSize(ctx->buf);
                *result = xmlStrndup(xmlOutputBufferGetContent(ctx->buf), *len);
#else
                *len    = ctx->buf->buffer->use;
                *result = xmlStrndup(ctx->buf->buffer->content, *len);
#endif
            }
        }

    }

    (void) xmlOutputBufferClose(ctx->buf);

    ctx->buf = NULL;
}

void
XMLHash_hash2xml(convert_ctx_t *ctx, SV *hash)
{
    if (ctx->opts.xml_decl) {
        /* xml declaration */
        BUFFER_WRITE_CONSTANT("<?xml version=");
        BUFFER_WRITE_QUOTED(ctx->opts.version);
        BUFFER_WRITE_CONSTANT(" encoding=");
        BUFFER_WRITE_QUOTED(ctx->opts.encoding);
        BUFFER_WRITE_CONSTANT("?>\n");
    }

    if (ctx->opts.method == CONV_METHOD_NATIVE) {
        ctx->opts.trim = 0;
        XMLHash_write_hash_no_attr(ctx, ctx->opts.root, hash);
    }
    else if (ctx->opts.method == CONV_METHOD_NATIVE_ATTR_MODE) {
        ctx->opts.trim = 0;
        XMLHash_write_hash(ctx, ctx->opts.root, hash);
    }
    else if (ctx->opts.method == CONV_METHOD_LX) {
        XMLHash_write_hash_lx(ctx, hash, 0);
    }
}

MODULE = XML::Hash::XS PACKAGE = XML::Hash::XS

PROTOTYPES: DISABLE

conv_opts_t *
new(class = "XML::Hash::XS",...)
        char *class;
    PREINIT:
        conv_opts_t  *conv_opts;
    CODE:
        if ((conv_opts = XMLHash_conv_create()) == NULL) {
            croak("Malloc error in new()");
        }

        dXCPT;
        XCPT_TRY_START
        {
            XMLHash_conv_parse_param(conv_opts, 1, ax, items);
        } XCPT_TRY_END

        XCPT_CATCH
        {
            XMLHash_conv_destroy(conv_opts);
            XCPT_RETHROW;
        }

        RETVAL = conv_opts;
    OUTPUT:
        RETVAL

SV *
hash2xml(...)
    PREINIT:
        conv_opts_t   *conv_opts = NULL;
        convert_ctx_t  ctx;
        SV            *p, *hash, *result;
        int            nparam    = 0;
    CODE:
        /* get object reference */
        if (nparam >= items)
            croak("Invalid parameters");

        p = ST(nparam);
        if ( sv_isa(p, "XML::Hash::XS") ) {
            /* reference to object */
            IV tmp = SvIV((SV *) SvRV(p));
            conv_opts = INT2PTR(conv_opts_t *, tmp);
            nparam++;
        }
        else if ( SvTYPE(p) == SVt_PV ) {
            /* class name */
            nparam++;
        }

        /* get hash reference */
        if (nparam >= items)
            croak("Invalid parameters");

        p = ST(nparam);
        if (SvROK(p) && SvTYPE(SvRV(p)) == SVt_PVHV) {
            hash = p;
            nparam++;
        }
        else {
            croak("Parameter is not hash reference");
        }

        /* set options */
        memset(&ctx, 0, sizeof(convert_ctx_t));
        if (conv_opts == NULL) {
            /* read global options */
            XMLHash_conv_init_options(&ctx.opts);
        }
        else {
            /* read options from object */
            memcpy(&ctx.opts, conv_opts, sizeof(conv_opts_t));
        }
        XMLHash_conv_parse_param(&ctx.opts, nparam, ax, items);

        /* run */
        dXCPT;
        XCPT_TRY_START
        {
            ctx.writer = XMLHash_writer_create(16384);

            XMLHash_hash2xml(&ctx, hash);

        } XCPT_TRY_END

        XCPT_CATCH
        {
            XMLHash_stash_clean(&ctx.stash);
            (void) XMLHash_writer_destroy(ctx.writer);
            XCPT_RETHROW;
        }

        XMLHash_stash_clean(&ctx.stash);
        result = XMLHash_writer_flush(ctx.writer);
        XMLHash_writer_destroy(ctx.writer);

        if (ctx.opts.output != NULL) {
            XSRETURN_UNDEF;
        }

        if (result == NULL) {
            warn("Failed to convert doc to string");
            XSRETURN_UNDEF;
        }
        else {
            RETVAL = result;
        }

    OUTPUT:
        RETVAL

void
DESTROY(conv)
        conv_opts_t *conv;
    CODE:
        XMLHash_conv_destroy(conv);

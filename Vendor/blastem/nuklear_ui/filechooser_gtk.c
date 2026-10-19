#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <gtk/gtk.h>
#include <dlfcn.h>

typedef GtkWidget* (*gtk_file_chooser_dialog_new_t)(const gchar *title, GtkWindow *parent, GtkFileChooserAction action, const gchar *first_button_text, ...);
typedef gint (*gtk_dialog_run_t)(GtkDialog *dialog);
typedef void (*gtk_widget_destroy_t)(GtkWidget *widget);
typedef gchar* (*gtk_file_chooser_get_filename_t)(GtkFileChooser *chooser);
typedef gboolean (*gtk_init_check_t)(int *argc, char **argv);
typedef gboolean (*gtk_file_chooser_set_current_folder_t)(GtkFileChooser *chooser, const gchar *filename);
typedef void (*gtk_file_chooser_setadd_filter_t)(GtkFileChooser *chooser, GtkFileFilter *filter);
typedef gboolean (*gtk_events_pending_t)(void);
typedef gboolean (*gtk_main_iteration_t)(void);
typedef GtkFileFilter* (*gtk_file_filter_new_t)(void);
typedef void (*gtk_file_filter_set_name_t)(GtkFileFilter *filter, const gchar *name);
typedef void (*gtk_file_filter_add_pattern_t)(GtkFileFilter *filter, const gchar *pattern);

typedef struct {
	gtk_file_chooser_dialog_new_t gtk_file_chooser_dialog_new;
	gtk_dialog_run_t gtk_dialog_run;
	gtk_widget_destroy_t gtk_widget_destroy;
	gtk_file_chooser_get_filename_t gtk_file_chooser_get_filename;
	gtk_file_chooser_set_current_folder_t gtk_file_chooser_set_current_folder;
	gtk_file_chooser_setadd_filter_t gtk_file_chooser_add_filter;
	gtk_file_chooser_setadd_filter_t gtk_file_chooser_set_filter;
	gtk_file_filter_new_t gtk_file_filter_new;
	gtk_file_filter_set_name_t gtk_file_filter_set_name;
	gtk_file_filter_add_pattern_t gtk_file_filter_add_pattern;
	gtk_init_check_t gtk_init_check;
	gtk_events_pending_t gtk_events_pending;
	gtk_main_iteration_t gtk_main_iteration;
} gtk;

#define LOAD_SYM(s, t, name) t->name = dlsym(s, #name); if (!t->name) { fputs("filechooser_gtk: Failed to load " #name "\n", stderr); goto error_cleanup; }

static gtk* check_init_gtk(void)
{
	static const char *so_paths[] = {
		"libgtk-3.so.0",
		"libgtk-x11-2.0.so.0",
	};
	static gtk *funcs;
	static uint8_t already_init;
	if (!already_init) {
		void *so = NULL;
		for (int i = 0; !so && i < sizeof(so_paths)/sizeof(*so_paths); i++)
		{
			so = dlopen(so_paths[i], RTLD_NOW | RTLD_LOCAL);
		}
		if (so) {
			funcs = calloc(1, sizeof(gtk));

			LOAD_SYM(so, funcs, gtk_file_chooser_dialog_new)
			LOAD_SYM(so, funcs, gtk_dialog_run)
			LOAD_SYM(so, funcs, gtk_widget_destroy)
			LOAD_SYM(so, funcs, gtk_file_chooser_get_filename)
			LOAD_SYM(so, funcs, gtk_file_chooser_set_current_folder)
			LOAD_SYM(so, funcs, gtk_file_chooser_add_filter)
			LOAD_SYM(so, funcs, gtk_file_chooser_set_filter)
			LOAD_SYM(so, funcs, gtk_file_filter_new)
			LOAD_SYM(so, funcs, gtk_file_filter_set_name)
			LOAD_SYM(so, funcs, gtk_file_filter_add_pattern)
			LOAD_SYM(so, funcs, gtk_init_check)
			LOAD_SYM(so, funcs, gtk_events_pending)
			LOAD_SYM(so, funcs, gtk_main_iteration)

			if (funcs->gtk_init_check(NULL, NULL)) {
				return funcs;
			}

error_cleanup:
			free(funcs);
			dlclose(so);
		}
	}
	return funcs;
}

uint8_t native_filechooser_available(void)
{
	return !!check_init_gtk();
}

char* native_filechooser_pick(const char *title, const char *start_directory)
{
	gtk *g = check_init_gtk();
	if (!g) {
		return NULL;
	}
	GtkFileChooser *chooser = (GtkFileChooser *)g->gtk_file_chooser_dialog_new(
		title, NULL, GTK_FILE_CHOOSER_ACTION_OPEN,
		"Cancel", GTK_RESPONSE_CANCEL,
		"Open", GTK_RESPONSE_ACCEPT,
		NULL
	);
	if (!chooser) {
		return NULL;
	}
	if (start_directory) {
		g->gtk_file_chooser_set_current_folder(chooser, start_directory);
	}
	GtkFileFilter *filter = g->gtk_file_filter_new();
	g->gtk_file_filter_set_name(filter, "All Files");
	g->gtk_file_filter_add_pattern(filter, "*");
	g->gtk_file_chooser_add_filter(chooser, filter);

	filter = g->gtk_file_filter_new();
	g->gtk_file_filter_set_name(filter, "All Supported Types");
	g->gtk_file_filter_add_pattern(filter, "*.zip");
	g->gtk_file_filter_add_pattern(filter, "*.bin");
	g->gtk_file_filter_add_pattern(filter, "*.bin.gz");
	g->gtk_file_filter_add_pattern(filter, "*.gen");
	g->gtk_file_filter_add_pattern(filter, "*.gen.gz");
	g->gtk_file_filter_add_pattern(filter, "*.md");
	g->gtk_file_filter_add_pattern(filter, "*.md.gz");
	g->gtk_file_filter_add_pattern(filter, "*.sms");
	g->gtk_file_filter_add_pattern(filter, "*.sms.gz");
	g->gtk_file_filter_add_pattern(filter, "*.gg");
	g->gtk_file_filter_add_pattern(filter, "*.gg.gz");
	g->gtk_file_filter_add_pattern(filter, "*.sg");
	g->gtk_file_filter_add_pattern(filter, "*.sg.gz");
	g->gtk_file_filter_add_pattern(filter, "*.cue");
	g->gtk_file_filter_add_pattern(filter, "*.toc");
	g->gtk_file_filter_add_pattern(filter, "*.flac");
	g->gtk_file_filter_add_pattern(filter, "*.vgm");
	g->gtk_file_filter_add_pattern(filter, "*.vgz");
	g->gtk_file_filter_add_pattern(filter, "*.vgm.gz");
	g->gtk_file_chooser_add_filter(chooser, filter);
	g->gtk_file_chooser_set_filter(chooser, filter);

	filter = g->gtk_file_filter_new();
	g->gtk_file_filter_set_name(filter, "Genesis/MD");
	g->gtk_file_filter_add_pattern(filter, "*.zip");
	g->gtk_file_filter_add_pattern(filter, "*.bin");
	g->gtk_file_filter_add_pattern(filter, "*.bin.gz");
	g->gtk_file_filter_add_pattern(filter, "*.gen");
	g->gtk_file_filter_add_pattern(filter, "*.gen.gz");
	g->gtk_file_filter_add_pattern(filter, "*.md");
	g->gtk_file_filter_add_pattern(filter, "*.md.gz");
	g->gtk_file_chooser_add_filter(chooser, filter);

	filter = g->gtk_file_filter_new();
	g->gtk_file_filter_set_name(filter, "Sega/Mega CD");
	g->gtk_file_filter_add_pattern(filter, "*.cue");
	g->gtk_file_filter_add_pattern(filter, "*.toc");
	g->gtk_file_chooser_add_filter(chooser, filter);

	filter = g->gtk_file_filter_new();
	g->gtk_file_filter_set_name(filter, "Sega 8-bit");
	g->gtk_file_filter_add_pattern(filter, "*.sms");
	g->gtk_file_filter_add_pattern(filter, "*.sms.gz");
	g->gtk_file_filter_add_pattern(filter, "*.gg");
	g->gtk_file_filter_add_pattern(filter, "*.gg.gz");
	g->gtk_file_filter_add_pattern(filter, "*.sg");
	g->gtk_file_filter_add_pattern(filter, "*.sg.gz");
	g->gtk_file_chooser_add_filter(chooser, filter);

	filter = g->gtk_file_filter_new();
	g->gtk_file_filter_set_name(filter, "Audio/VGM");
	g->gtk_file_filter_add_pattern(filter, "*.flac");
	g->gtk_file_filter_add_pattern(filter, "*.vgm");
	g->gtk_file_filter_add_pattern(filter, "*.vgz");
	g->gtk_file_filter_add_pattern(filter, "*.vgm.gz");
	g->gtk_file_chooser_add_filter(chooser, filter);

	char *ret = NULL;
	if (GTK_RESPONSE_ACCEPT == g->gtk_dialog_run((GtkDialog*)chooser)) {
		ret = g->gtk_file_chooser_get_filename(chooser);
	}
	g->gtk_widget_destroy((GtkWidget *)chooser);
	while (g->gtk_events_pending())
	{
		g->gtk_main_iteration();
	}
	return ret;
}

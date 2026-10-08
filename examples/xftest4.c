/*
 * xftest4.c — a borderless XForms form with a pulldown menu.
 *
 * The other three examples use FL_FULLBORDER, which asks the window manager for
 * a decorated window.  FL_NOBORDER does the opposite: XForms then sets
 * override-redirect on the form's window (lib/win.c, CWOverrideRedirect), so on
 * X the window bypasses the window manager and is shown undecorated at the
 * geometry the application chose.  It is how an XForms program asks for a window
 * with no title bar.
 *
 * The combination with a pulldown menu is what makes this worth testing.  It
 * leaves the client with no window that a Wayland implementation would call an
 * ordinary toplevel: the form is the override-redirect one, and the menu shell
 * that drops out of it is override-redirect as well, so there is nothing to
 * anchor the menu to.  Both have to work for the program to be usable -- the form
 * has to be shown at all, and the menu has to drop down on it as a popup of that
 * form, not as a second unconnected window.
 *
 * Both the menu object's geometry and the form's are printed as the form is
 * built, so the input script's coordinates can be checked against the program
 * rather than guessed (see inputs/xftest4.input).
 */

#include <stdio.h>
#include <stdlib.h>
#include <forms.h>

/* A FL_CALLBACKPTR, whose second argument is a long rather than a pointer.
 *
 * This exits rather than calling fl_end_form(), which is what the other three
 * examples do.  It is called from the *menu shell's* context when a pulldown
 * item is chosen, and fl_end_form() there ends the shell rather than the main
 * form, so the main event loop would keep running.  The subject of this example
 * is whether the menu can be opened and its item chosen at all, so a marker on
 * stdout and exit status 0 is the whole assertion. */
static void quit_cb(FL_OBJECT *obj, long data)
{
    printf("QUIT %s\n", obj && obj->label ? obj->label : "?");
    fflush(stdout);
    exit(0);
}

int main(int argc, char **argv)
{
    FL_FORM *form;
    FL_OBJECT *file, *quit;

    fl_initialize(&argc, argv, 0, 0, 0);

    form = fl_bgn_form(FL_UP_BOX, 300, 200);
    /* A touch menu keeps its shell down while the button is held, so the script
     * has to press, move onto the item, then release. */
    file = fl_add_menu(FL_TOUCH_MENU, 20, 20, 80, 25, "File");
    fl_set_menu(file, "Quit\tQ");
    fl_set_object_callback(file, quit_cb, 0);
    fl_add_box(FL_FLAT_BOX, 20, 70, 260, 60, "A borderless form");
    quit = fl_add_button(FL_NORMAL_BUTTON, 100, 150, 100, 30, "Quit");
    fl_set_object_callback(quit, quit_cb, 0);
    fl_end_form();

    printf("GEO:FORM    x=%d y=%d w=%d h=%d\n", form->x, form->y, form->w, form->h);
    printf("GEO:FILE    x=%d y=%d w=%d h=%d\n", file->x, file->y, file->w, file->h);
    printf("GEO:QUITBTN x=%d y=%d w=%d h=%d\n", quit->x, quit->y, quit->w, quit->h);
    fflush(stdout);

    /* FL_NOBORDER: override-redirect, undecorated. */
    fl_show_form(form, FL_PLACE_CENTER, FL_NOBORDER, "Borderless");
    printf("GEO:SHOWN   visible=%d win=0x%lx\n", form->visible,
           (unsigned long) form->window);
    fflush(stdout);

    fl_do_forms();
    fl_finish();
    return 0;
}
